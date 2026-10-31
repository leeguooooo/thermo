import AVFoundation
import Foundation
import Network
import XCTest
@testable import MediaToolsKit

/// A real HTTP/1.1 server on loopback.
private final class LocalServer: @unchecked Sendable {
    struct Request { var path: String; var headers: [String: String] }
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "local-server")
    private let lock = NSLock()
    private var seen: [Request] = []
    private var broken = 0
    var brokenSends: Int { lock.withLock { broken } }
    private let handler: @Sendable (Request) -> Reply
    private(set) var port: UInt16 = 0
    var requests: [Request] { lock.withLock { seen } }
    var baseURL: String { "http://127.0.0.1:\(port)" }

    init(handler: @escaping @Sendable (Request) -> Reply) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.read(connection, Data())
        }
        let ready: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let listener = self.listener
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = ready
    }

    deinit { listener.cancel() }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            let first = lock.withLock { () -> Bool in
                defer { done = true }
                return !done
            }
            if first { body() }
        }
    }

    private func read(_ connection: NWConnection, _ received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, end, error in
            guard let self else { return }
            var all = received
            if let data { all.append(data) }
            if let split = all.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: String(decoding: all[..<split.lowerBound], as: UTF8.self))
            } else if !end, error == nil {
                self.read(connection, all)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let path = lines[0].split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let request = Request(path: path, headers: headers)
        lock.withLock { seen.append(request) }
        let reply = handler(request)
        var text = "HTTP/1.1 \(reply.status) X\r\nConnection: close\r\nContent-Length: \(reply.body.count)\r\n"
        for (name, value) in reply.headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        send(connection, Data(text.utf8) + reply.body)
    }

    private func send(_ connection: NWConnection, _ data: Data) {
        let piece = data.prefix(1 << 18)
        let rest = data.dropFirst(piece.count)
        connection.send(content: piece, completion: .contentProcessed { [weak self] error in
            guard let self else { return connection.cancel() }
            if error != nil {
                self.lock.withLock { self.broken += 1 }
                connection.cancel()
            } else if rest.isEmpty {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else {
                self.send(connection, Data(rest))
            }
        })
    }

    /// Serves `content`, honoring `Range` when asked to.
    static func ranged(_ content: Data, ranges: Bool = true, extra: [String: String] = ["ETag": "\"v1\""]) -> @Sendable (Request) -> Reply {
        { request in
            guard ranges, let header = request.headers["range"], header.hasPrefix("bytes=") else {
                return Reply(headers: extra, body: content)
            }
            let bounds = header.dropFirst(6).split(separator: "-").compactMap { Int($0) }
            let upper = min(bounds[1], content.count - 1)
            var headers = extra
            headers["Content-Range"] = "bytes \(bounds[0])-\(upper)/\(content.count)"
            return Reply(status: 206, headers: headers, body: content.subdata(in: bounds[0]..<(upper + 1)))
        }
    }
}

final class MediaPreviewRelayTests: XCTestCase {
    private func fetch(_ url: URL, range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(range, forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    private func relay(_ url: URL, headers: [String: String], kind: MediaPreview.Kind = .mp4) throws -> URL {
        let asset = try XCTUnwrap(MediaPreviewRelay.makeAsset(url: url, headers: headers, kind: kind))
        retained.append(asset)
        return asset.url
    }

    private var retained: [AnyObject] = []

    /// AVURLAsset's own header option sent `Cookie` to the other origin here; see the relay's comment.
    func testCredentialsStopAtTheOriginAcrossARedirect() async throws {
        let target = try await LocalServer { _ in .init(headers: ["Content-Type": "video/mp4"], body: Data("movie".utf8)) }
        let origin = try await LocalServer { _ in .init(status: 302, headers: ["Location": target.baseURL + "/b.mp4"]) }
        let local = try relay(URL(string: origin.baseURL + "/a.mp4")!, headers: ["Cookie": "secret", "Referer": "r", "User-Agent": "u"])
        XCTAssertEqual(local.host, "127.0.0.1")
        XCTAssertFalse(local.absoluteString.contains("secret"))
        let (data, response) = try await fetch(local, range: "bytes=0-4")
        XCTAssertEqual(data, Data("movie".utf8))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(origin.requests.first?.headers["cookie"], "secret")
        let landed = try XCTUnwrap(target.requests.first?.headers)
        XCTAssertNil(landed["cookie"])
        XCTAssertNil(landed["referer"])
        XCTAssertEqual(landed["user-agent"], "u")
        XCTAssertEqual(landed["range"], "bytes=0-4")
    }

    func testPlaylistKeepsSameOriginOnTheRelayAndSendsOthersDirect() async throws {
        let origin = try await LocalServer { request in
            request.path == "/m" ? .init(headers: ["Content-Type": "application/vnd.apple.mpegurl"],
                                         body: Data("#EXTM3U\n#EXTINF:1,\ns1.ts\n#EXTINF:1,\nhttp://cdn.test/s2.ts\n".utf8))
                : .init(body: Data("seg".utf8))
        }
        let local = try relay(URL(string: origin.baseURL + "/m")!, headers: ["Cookie": "c"], kind: .hls)
        let (data, _) = try await fetch(local)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[2].hasPrefix("http://127.0.0.1"))
        XCTAssertEqual(lines[4], "http://cdn.test/s2.ts")
        let (segment, _) = try await fetch(try XCTUnwrap(URL(string: lines[2])))
        XCTAssertEqual(segment, Data("seg".utf8))
        XCTAssertEqual(origin.requests.last?.path, "/s1.ts")
        XCTAssertEqual(origin.requests.last?.headers["cookie"], "c")
    }

    func testAPathWithoutTheTokenReachesNothing() async throws {
        let origin = try await LocalServer { _ in .init() }
        let local = try relay(URL(string: origin.baseURL + "/a.mp4")!, headers: ["Cookie": "c"])
        var parts = local.pathComponents
        parts[1] = UUID().uuidString
        let forged = URL(string: "http://127.0.0.1:\(local.port!)" + parts.joined(separator: "/").dropFirst())!
        let (_, response) = try await fetch(forged)
        XCTAssertEqual(response.statusCode, 404)
        XCTAssertTrue(origin.requests.isEmpty)
    }

    func testPlayerNeverSeesHeaders() throws {
        let player = try XCTUnwrap(MediaPreview.makePlayer(url: URL(string: "https://a.test/v.mp4")!, headers: ["Cookie": "c"]))
        retained.append(player)
        XCTAssertEqual((player.currentItem?.asset as? AVURLAsset)?.url.host, "127.0.0.1")
    }
}
