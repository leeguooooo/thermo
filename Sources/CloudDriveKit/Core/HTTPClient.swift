import Foundation

public enum HTTPMethod: String, Sendable { case get = "GET", post = "POST" }

public struct HTTPRequest: Sendable, Equatable {
    public var method: HTTPMethod
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public init(method: HTTPMethod, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    /// One `name=value; attributes` entry per cookie, never comma-joined.
    public var setCookies: [String]
    public var body: Data
    /// `name=value; Path=...` entries, for providers that need the path. Empty when the transport has none.
    public var cookiesWithPath: [String]
    public init(statusCode: Int = 200, setCookies: [String] = [], body: Data = Data(), cookiesWithPath: [String] = []) {
        self.statusCode = statusCode
        self.setCookies = setCookies
        self.body = body
        self.cookiesWithPath = cookiesWithPath
    }
}

/// The single network seam, so providers can be tested with recorded responses.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Sends explicit Cookie headers only. Nothing reaches a disk cookie jar, cache or credential store.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        session = URLSession(configuration: Self.makeConfiguration())
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // YunX HttpClients.apiClient: read 30 s, call 45 s.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        return configuration
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await session.data(for: urlRequest, delegate: RedirectGuard())
            guard let http = response as? HTTPURLResponse else { throw DriveError.transport(code: 0) }
            return HTTPResponse(statusCode: http.statusCode, setCookies: Self.setCookies(from: http), body: data,
                                cookiesWithPath: Self.cookiesWithPath(from: http))
        } catch let error as URLError {
            // URLError carries the URL, which can hold share tokens; keep only the code.
            if error.code == .cancelled { throw CancellationError() }
            throw DriveError.transport(code: error.errorCode)
        }
    }

    /// URLSession folds Set-Cookie headers into one comma-joined value, and cookie dates contain commas.
    static func setCookies(from response: HTTPURLResponse) -> [String] {
        guard let url = response.url else { return [] }
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, field in
            if let name = field.key as? String, let value = field.value as? String { result[name] = value }
        }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).map { "\($0.name)=\($0.value)" }
    }

    static func cookiesWithPath(from response: HTTPURLResponse) -> [String] {
        guard let url = response.url else { return [] }
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, field in
            if let name = field.key as? String, let value = field.value as? String { result[name] = value }
        }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).map { "\($0.name)=\($0.value); Path=\($0.path)" }
    }

    /// Credentials must not follow a redirect to another origin.
    static func redirected(_ request: URLRequest, from original: URL?) -> URLRequest {
        guard original?.host?.lowercased() != request.url?.host?.lowercased() || original?.scheme != request.url?.scheme else {
            return request
        }
        var stripped = request
        stripped.setValue(nil, forHTTPHeaderField: "Cookie")
        stripped.setValue(nil, forHTTPHeaderField: "Authorization")
        return stripped
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(URLSessionTransport.redirected(request, from: response.url))
    }
}

/// Provider-facing wrapper: default headers, JSON bodies and an injectable transport.
public struct HTTPClient: Sendable {
    private let transport: any HTTPTransport
    private let defaultHeaders: [String: String]

    public init(transport: any HTTPTransport = URLSessionTransport(), defaultHeaders: [String: String] = [:]) {
        self.transport = transport
        self.defaultHeaders = defaultHeaders
    }

    public func get(_ url: String, headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await send(.get, url, headers: headers, body: nil)
    }

    public func postJSON(_ url: String, json: [String: Any], headers: [String: String] = [:]) async throws -> HTTPResponse {
        let body = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
        var merged = headers
        merged["Content-Type"] = "application/json"
        return try await send(.post, url, headers: merged, body: body)
    }

    private func send(_ method: HTTPMethod, _ url: String, headers: [String: String], body: Data?) async throws -> HTTPResponse {
        guard let parsed = URL(string: url) else { throw DriveError.api(message: "请求地址无效") }
        let merged = defaultHeaders.merging(headers) { _, new in new }
        return try await transport.send(HTTPRequest(method: method, url: parsed, headers: merged, body: body))
    }

    /// Matches java.net.URLEncoder, which the source drives use: `+`, `/` and `=` are escaped.
    public static func encodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._*")
        return (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "").replacingOccurrences(of: "%20", with: "+")
    }
}
