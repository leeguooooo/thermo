import Foundation

public struct VideoRequest: Sendable, Equatable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var followRedirects: Bool

    public init(
        url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        followRedirects: Bool = true
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.followRedirects = followRedirects
    }
}

public struct VideoResponse: Sendable, Equatable {
    public var status: Int
    public var body: String
    public var headers: [String: String]
    public var finalUrl: String

    public init(status: Int, body: String = "", headers: [String: String] = [:], finalUrl: String = "") {
        self.status = status
        self.body = body
        self.headers = headers
        self.finalUrl = finalUrl
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Network seam. Throw `CancellationError` on cancellation; any other error becomes `.network`.
public protocol VideoTransport: Sendable {
    func send(_ request: VideoRequest) async throws -> VideoResponse
}

/// HTTP helpers shared by the parsers: status mapping, short-link expansion, inline JSON.
public struct VideoHttp: Sendable {
    public static let uaChrome =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " +
        "Chrome/131.0.0.0 Safari/537.36"

    public static let uaIphone =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private let transport: any VideoTransport

    public init(transport: any VideoTransport = URLSessionVideoTransport()) {
        self.transport = transport
    }

    public func request(
        _ url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        followRedirects: Bool = true
    ) async throws -> VideoResponse {
        let upper = method.uppercased()
        do {
            return try await transport.send(VideoRequest(
                url: url,
                method: upper,
                headers: headers,
                // A POST always has a body, as OkHttp's empty FormBody does.
                body: body ?? (upper == "POST" ? Data() : nil),
                followRedirects: followRedirects
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as VideoParseException {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw VideoParseException(.network, "请求失败：\(Self.redactedURL(url))")
        }
    }

    public static func requireSuccess(_ response: VideoResponse, what: String) throws {
        switch response.status {
        case 200...299:
            return
        case 403, 418, 429:
            throw VideoParseException(.blocked, "\(what) 被风控拦截（HTTP \(response.status)）")
        case 404, 410:
            throw VideoParseException(.notFound, "\(what) 不存在（HTTP \(response.status)）")
        default:
            throw VideoParseException(.unknown, "\(what) 请求失败（HTTP \(response.status)）")
        }
    }

    public func getText(_ url: String, headers: [String: String] = [:], what: String = "解析") async throws -> String {
        let response = try await request(url, headers: headers)
        try Self.requireSuccess(response, what: what)
        return response.body
    }

    func getJson(_ url: String, headers: [String: String] = [:], what: String = "解析") async throws -> VideoJSONObject {
        let text = try await getText(url, headers: headers, what: what)
        guard let object = VideoJSON.parseObject(text) else {
            throw VideoParseException(.unknown, "\(what) 返回的不是合法 JSON")
        }
        return object
    }

    /// Form pairs keep their order on the wire.
    public func postForm(
        _ url: String,
        form: [(key: String, value: String)],
        headers: [String: String] = [:],
        what: String = "解析"
    ) async throws -> String {
        var allHeaders = headers
        if !headers.keys.contains(where: { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
            allHeaders["Content-Type"] = "application/x-www-form-urlencoded"
        }
        let encoded = form.map { "\(Self.formEncode($0.key))=\(Self.formEncode($0.value))" }.joined(separator: "&")
        let response = try await request(url, method: "POST", headers: allHeaders, body: Data(encoded.utf8))
        try Self.requireSuccess(response, what: what)
        return response.body
    }

    /// Follows one redirect. Returns nil when there is no target; the caller decides what that means.
    public func expandRedirect(_ url: String, headers: [String: String] = [:]) async throws -> String? {
        let response = try await request(url, headers: headers, followRedirects: false)
        if (300...399).contains(response.status) { return response.header("Location") }
        return response.finalUrl != url ? response.finalUrl : nil
    }

    /// Extracts the text of `key = ...stopAt`, the shape of `window.XXX = {...}</script>`.
    public static func extractInlineJson(_ html: String, key: String, stopAt: String = "</script>") -> String? {
        var searchStart = html.startIndex
        while let keyRange = html.range(of: key, options: .literal, range: searchStart..<html.endIndex) {
            searchStart = keyRange.upperBound
            var cursor = keyRange.upperBound
            while cursor < html.endIndex, html[cursor].isWhitespace { cursor = html.index(after: cursor) }
            guard cursor < html.endIndex, html[cursor] == "=" else { continue }
            cursor = html.index(after: cursor)
            while cursor < html.endIndex, html[cursor].isWhitespace { cursor = html.index(after: cursor) }
            guard let stop = html.range(of: stopAt, options: .literal, range: cursor..<html.endIndex) else { return nil }
            return html[cursor..<stop.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// AcFun's inline JSON is escaped one level.
    public static func unescapeQuotes(_ text: String) -> String {
        text.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\/", with: "/")
    }

    /// Upgrades cleartext and protocol-relative links; these CDNs all serve https.
    public static func secureUrl(_ url: String) -> String {
        if url.hasPrefix("//") { return "https:\(url)" }
        if url.hasPrefix("http://") { return "https://\(url.dropFirst("http://".count))" }
        return url
    }

    /// Scheme, host and path only, safe for logs and error messages.
    public static func redactedURL(_ url: String) -> String {
        String(url.prefix { $0 != "?" && $0 != "#" })
    }

    private static func formEncode(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x2A:
                out.unicodeScalars.append(Unicode.Scalar(byte))
            case 0x20:
                out.append("+")
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}

/// Ephemeral session with cookie handling off, so only the explicit Cookie header is ever sent
/// and nothing lands in a shared cookie store or URL cache.
public final class URLSessionVideoTransport: NSObject, VideoTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let session: URLSession

    public override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)
        super.init()
    }

    public func send(_ request: VideoRequest) async throws -> VideoResponse {
        guard let url = URL(string: request.url), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw URLError(.badURL)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }

        let delegate = RedirectPolicy(follow: request.followRedirects)
        do {
            let (data, response) = try await session.data(for: urlRequest, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                if let name = name as? String, let value = value as? String { headers[name] = value }
            }
            return VideoResponse(
                status: http.statusCode,
                body: String(decoding: data, as: UTF8.self),
                headers: headers,
                finalUrl: http.url?.absoluteString ?? request.url
            )
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }
}

private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let follow: Bool

    init(follow: Bool) {
        self.follow = follow
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard follow else { return completionHandler(nil) }
        var next = request
        // A login Cookie must not follow a redirect to another host.
        if task.originalRequest?.url?.host?.lowercased() != request.url?.host?.lowercased() {
            next.setValue(nil, forHTTPHeaderField: "Cookie")
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }
}
