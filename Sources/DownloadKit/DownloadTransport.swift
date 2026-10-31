import Foundation

public struct FetchRequest: Sendable, Equatable {
    public var url: URL
    public var headers: [String: String]
    /// Half-open byte range; nil asks for the whole resource.
    public var range: Range<Int64>?

    public init(url: URL, headers: [String: String] = [:], range: Range<Int64>? = nil) {
        self.url = url
        self.headers = headers
        self.range = range
    }
}

public struct HTTPResponseInfo: Sendable, Equatable {
    public var statusCode: Int
    /// Header names are lowercased on init.
    public var headers: [String: String]

    public init(statusCode: Int, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
    }

    public var contentLength: Int64? {
        headers["content-length"].flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 >= 0 ? $0 : nil }
    }

    /// True when the body is transformed, so byte offsets do not match the stored resource.
    public var isEncoded: Bool {
        guard let encoding = headers["content-encoding"]?.lowercased() else { return false }
        return !encoding.isEmpty && encoding != "identity"
    }

    /// Parses `bytes <first>-<last>/<total|*>`.
    public var contentRange: (start: Int64, total: Int64?)? {
        guard var value = headers["content-range"]?.trimmingCharacters(in: .whitespaces).lowercased(),
              value.hasPrefix("bytes ") else { return nil }
        value.removeFirst("bytes ".count)
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)), start >= 0 else { return nil }
        return (start, Int64(parts[1].trimmingCharacters(in: .whitespaces)))
    }

    /// Strong ETag, else Last-Modified. A weak ETag cannot vouch for byte ranges.
    public var validator: String? {
        if let etag = headers["etag"], !etag.hasPrefix("W/"), !etag.isEmpty { return etag }
        return headers["last-modified"]
    }
}

public struct FetchResponse: Sendable {
    public var info: HTTPResponseInfo
    /// Dropping the stream must stop the underlying request.
    public var body: AsyncThrowingStream<Data, Error>

    public init(info: HTTPResponseInfo, body: AsyncThrowingStream<Data, Error>) {
        self.info = info
        self.body = body
    }
}

/// The only way the engine reaches the network, so tests can script every response.
public protocol DownloadTransport: Sendable {
    func fetch(_ request: FetchRequest) async throws -> FetchResponse
}

/// Transport over URLSession. One short-lived session per fetch keeps the delegate state simple.
public struct URLSessionTransport: DownloadTransport {
    public init() {}

    public func fetch(_ request: FetchRequest) async throws -> FetchResponse {
        let urlRequest = Self.makeRequest(request)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        let delegate = FetchDelegate(original: urlRequest)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: urlRequest)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.begin(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func makeRequest(_ request: FetchRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData)
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        // Compressed bodies would break the mapping from offsets to bytes.
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range = request.range {
            urlRequest.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        } else {
            urlRequest.setValue(nil, forHTTPHeaderField: "Range")
        }
        return urlRequest
    }

    /// Caller headers can carry credentials: they only follow a redirect to the same origin,
    /// and a redirect from https down to http is refused.
    static func redirectRequest(original: URLRequest, proposed: URLRequest) -> URLRequest? {
        guard let from = original.url, let to = proposed.url else { return nil }
        if from.scheme?.lowercased() == "https", to.scheme?.lowercased() != "https" { return nil }
        let sameOrigin = from.scheme?.lowercased() == to.scheme?.lowercased()
            && from.host?.lowercased() == to.host?.lowercased()
            && from.port == to.port
        if sameOrigin { return proposed }
        var stripped = proposed
        for name in (proposed.allHTTPHeaderFields ?? [:]).keys {
            let lower = name.lowercased()
            if lower != "range" && lower != "accept-encoding" {
                stripped.setValue(nil, forHTTPHeaderField: name)
            }
        }
        return stripped
    }
}

private final class FetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let original: URLRequest
    private let lock = NSLock()
    private var continuation: CheckedContinuation<FetchResponse, Error>?
    private var body: AsyncThrowingStream<Data, Error>.Continuation?

    init(original: URLRequest) {
        self.original = original
    }

    func begin(_ continuation: CheckedContinuation<FetchResponse, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(URLSessionTransport.redirectRequest(original: original, proposed: request))
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        let (stream, streamContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        streamContinuation.onTermination = { termination in
            if case .cancelled = termination { dataTask.cancel() }
        }
        let waiting = lock.withLock { () -> CheckedContinuation<FetchResponse, Error>? in
            let waiting = continuation
            continuation = nil
            body = streamContinuation
            return waiting
        }
        waiting?.resume(returning: FetchResponse(info: HTTPResponseInfo(statusCode: http.statusCode, headers: headers), body: stream))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        _ = lock.withLock { body }?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (waiting, stream) = lock.withLock { () -> (CheckedContinuation<FetchResponse, Error>?, AsyncThrowingStream<Data, Error>.Continuation?) in
            defer { continuation = nil; body = nil }
            return (continuation, body)
        }
        waiting?.resume(throwing: error ?? URLError(.badServerResponse))
        stream?.finish(throwing: error)
        session.finishTasksAndInvalidate()
    }
}
