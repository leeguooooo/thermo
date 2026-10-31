import AVFoundation
import Foundation
import Network
import ObjectiveC

/// What a preview request may carry, and where a playlist's entries must go.
enum MediaPreviewPolicy {
    private static let crossOriginHeaders: Set<String> = ["accept", "accept-encoding", "accept-language", "range", "user-agent"]

    static func headers(for target: URL, credentialOrigin: URL, headers: [String: String]) -> [String: String] {
        if sameOrigin(target, credentialOrigin) { return headers }
        return headers.filter { crossOriginHeaders.contains($0.key.lowercased()) }
    }

    static func sameOrigin(_ left: URL, _ right: URL) -> Bool {
        left.scheme?.lowercased() == right.scheme?.lowercased() && left.host?.lowercased() == right.host?.lowercased()
            && effectivePort(left) == effectivePort(right)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil)
    }

    /// Same-origin entries stay on the relay, which holds the credentials. Others become absolute
    /// real URLs, so AVPlayer fetches them with no credentials at all.
    static func rewritePlaylist(_ text: String, base: URL, origin: URL, relay: (URL) -> URL?) -> String {
        func route(_ entry: String) -> String {
            guard let target = URL(string: entry, relativeTo: base)?.absoluteURL else { return entry }
            if sameOrigin(target, origin), let relayed = relay(target) { return relayed.absoluteString }
            return target.absoluteString
        }
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line -> String in
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { return "" }
            guard value.hasPrefix("#") else { return route(value) }
            guard let found = value.range(of: "URI=\"[^\"]+\"", options: .regularExpression) else { return value }
            let entry = String(value[found].dropFirst(5).dropLast())
            return value.replacingCharacters(in: found, with: "URI=\"\(route(entry))\"")
        }.joined(separator: "\n")
    }
}

/// Keeps `headers` off `AVURLAsset`, which repeats them on every redirect and segment whatever the
/// origin, including `Cookie`. AVPlayer talks to this relay on 127.0.0.1 and the relay decides the
/// headers per hop. A resource loader cannot do this: AVFoundation refuses HLS segments served
/// through one (-12881). Each path carries a random token, so other local processes cannot use it.
final class MediaPreviewRelay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let maxPlaylistBytes = 1 << 20
    private static let highWater = 8 << 20
    private static let lowWater = 2 << 20
    private static let maxRequestHead = 16 << 10
    nonisolated(unsafe) private static var ownerKey: UInt8 = 0

    private final class Exchange {
        let connection: NWConnection
        let playlist: Bool
        var task: URLSessionDataTask?
        var buffer = Data()
        var isPlaylist = false
        var pending = 0
        var suspended = false
        init(_ connection: NWConnection, playlist: Bool) { self.connection = connection; self.playlist = playlist }
    }

    /// The session holds the relay strongly, so the asset owns this and everything ends with the asset.
    private final class Owner: NSObject {
        let relay: MediaPreviewRelay
        init(_ relay: MediaPreviewRelay) { self.relay = relay }
        deinit { relay.close() }
    }

    private let origin: URL
    private let headers: [String: String]
    private let hls: Bool
    private let token = UUID().uuidString
    private let queue = DispatchQueue(label: "media-preview-relay")
    private let listener: NWListener
    private var session: URLSession?
    private var exchanges: [Int: Exchange] = [:]
    private var entry = ""

    private init?(origin: URL, headers: [String: String], hls: Bool) {
        self.origin = origin
        self.headers = headers
        self.hls = hls
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let operations = OperationQueue()
        operations.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: operations)
    }

    static func makeAsset(url: URL, headers: [String: String], kind: MediaPreview.Kind) -> AVURLAsset? {
        guard let relay = MediaPreviewRelay(origin: url, headers: headers, hls: kind == .hls), let local = relay.start(url) else { return nil }
        let asset = AVURLAsset(url: local)
        objc_setAssociatedObject(asset, &ownerKey, Owner(relay), .OBJC_ASSOCIATION_RETAIN)
        return asset
    }

    /// Returns the local address of `url`, or nil when loopback could not be bound in time.
    func start(_ url: URL) -> URL? {
        let ready = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success, listener.state == .ready, let local = relayed(url) else {
            close()
            return nil
        }
        entry = local.path
        return local
    }

    func close() {
        listener.cancel()
        session?.invalidateAndCancel()
        session = nil
    }

    /// The real URL travels in the path, so the relay needs no table that grows with a playlist.
    /// The last component keeps its extension because AVPlayer looks at it.
    private func relayed(_ url: URL) -> URL? {
        guard let port = listener.port?.rawValue else { return nil }
        let encoded = Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        return URL(string: "http://127.0.0.1:\(port)/\(token)/\(encoded)/media\(suffix)")
    }

    private func target(of path: String) -> URL? {
        let parts = path.split(separator: "/")
        guard parts.count == 3, parts[0] == token else { return nil }
        var text = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text).flatMap { String(data: $0, encoding: .utf8) }.flatMap(URL.init(string:))
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHead(connection, Data())
    }

    private func readHead(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            let head = received + (data ?? Data())
            if let end = head.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(String(decoding: head[..<end.lowerBound], as: UTF8.self), connection)
            } else if error == nil, !complete, head.count < Self.maxRequestHead {
                self.readHead(connection, head)
            } else {
                connection.cancel()
            }
        }
    }

    private func handle(_ head: String, _ connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count >= 2, ["GET", "HEAD"].contains(String(start[0])), let url = target(of: String(start[1])), let session else {
            return reply("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", connection)
        }
        var request = URLRequest(url: url)
        request.httpMethod = String(start[0])
        apply(MediaPreviewPolicy.headers(for: url, credentialOrigin: origin, headers: headers), to: &request)
        // Without this, URLSession inflates the body and the forwarded length no longer fits.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let playlist = (hls && String(start[1]) == entry) || url.pathExtension.lowercased() == "m3u8"
        if !playlist, let range = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("range:") }) {
            request.setValue(range.dropFirst(6).trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "Range")
        }
        let exchange = Exchange(connection, playlist: playlist)
        let task = session.dataTask(with: request)
        exchange.task = task
        exchanges[task.taskIdentifier] = exchange
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: task.cancel()
            default: break
            }
        }
        task.resume()
    }

    private func reply(_ text: String, _ connection: NWConnection) {
        connection.send(content: Data(text.utf8), isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func apply(_ headers: [String: String], to request: inout URLRequest) {
        for name in (request.allHTTPHeaderFields ?? [:]).keys { request.setValue(nil, forHTTPHeaderField: name) }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    }

    /// URLSession copies every header onto a redirect, so each hop is decided again here.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url, ["http", "https"].contains(target.scheme?.lowercased() ?? "") else { return completionHandler(nil) }
        var next = request
        let range = task.originalRequest?.value(forHTTPHeaderField: "Range")
        apply(MediaPreviewPolicy.headers(for: target, credentialOrigin: origin, headers: headers), to: &next)
        next.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range { next.setValue(range, forHTTPHeaderField: "Range") }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let exchange = exchanges[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
            return completionHandler(.cancel)
        }
        exchange.isPlaylist = (200..<300).contains(http.statusCode)
            && (exchange.playlist || http.mimeType?.lowercased().contains("mpegurl") == true)
        if !exchange.isPlaylist {
            var head = "HTTP/1.1 \(http.statusCode) OK\r\nConnection: close\r\n"
            for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"] {
                if let value = http.value(forHTTPHeaderField: name) { head += "\(name): \(value)\r\n" }
            }
            exchange.connection.send(content: Data((head + "\r\n").utf8), completion: .idempotent)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let exchange = exchanges[dataTask.taskIdentifier] else { return }
        if exchange.isPlaylist {
            exchange.buffer.append(data)
            if exchange.buffer.count > Self.maxPlaylistBytes { dataTask.cancel() }
            return
        }
        exchange.pending += data.count
        if exchange.pending > Self.highWater, !exchange.suspended {
            exchange.suspended = true
            dataTask.suspend()
        }
        exchange.connection.send(content: data, completion: .contentProcessed { [weak exchange] _ in
            guard let exchange else { return }
            exchange.pending -= data.count
            if exchange.suspended, exchange.pending < Self.lowWater {
                exchange.suspended = false
                exchange.task?.resume()
            }
        })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let exchange = exchanges.removeValue(forKey: task.taskIdentifier) else { return }
        if error != nil { return exchange.connection.cancel() }
        if exchange.isPlaylist, let base = task.response?.url {
            let text = MediaPreviewPolicy.rewritePlaylist(
                String(decoding: exchange.buffer, as: UTF8.self), base: base, origin: origin, relay: relayed)
            let body = Data(text.utf8)
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            exchange.connection.send(content: Data(head.utf8), completion: .idempotent)
            exchange.connection.send(content: body, completion: .idempotent)
        }
        let connection = exchange.connection
        connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }
}
