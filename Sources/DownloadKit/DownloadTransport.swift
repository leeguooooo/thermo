import Foundation

public struct FetchRequest: Sendable, Equatable {
    public var url: URL
    public var headers: [String: String]
    /// Half-open byte range; nil asks for the whole resource.
    public var range: Range<Int64>?
    /// False returns a 3xx as the response, for callers applying their own origin policy.
    public var followRedirects: Bool

    public init(url: URL, headers: [String: String] = [:], range: Range<Int64>? = nil, followRedirects: Bool = true) {
        self.url = url
        self.headers = headers
        self.range = range
        self.followRedirects = followRedirects
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

    public var contentRange: HTTPRangePolicy.ContentRange? {
        HTTPRangePolicy.parse(headers["content-range"])
    }

    public var isHTML: Bool {
        headers["content-type"]?.lowercased().contains("text/html") ?? false
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
/// A slow reader holds back delivery, so the body never buffers more than about `maxBufferedBytes`.
public struct URLSessionTransport: DownloadTransport {
    public static let defaultMaxBufferedBytes = 4 << 20

    let maxBufferedBytes: Int
    /// Reports the buffered byte count after each delivery.
    let bufferObserver: (@Sendable (Int) -> Void)?

    public init(maxBufferedBytes: Int = URLSessionTransport.defaultMaxBufferedBytes) {
        self.init(maxBufferedBytes: maxBufferedBytes, bufferObserver: nil)
    }

    init(maxBufferedBytes: Int, bufferObserver: (@Sendable (Int) -> Void)?) {
        self.maxBufferedBytes = max(1, maxBufferedBytes)
        self.bufferObserver = bufferObserver
    }

    public func fetch(_ request: FetchRequest) async throws -> FetchResponse {
        let urlRequest = Self.makeRequest(request)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        let delegate = FetchDelegate(
            original: urlRequest, followRedirects: request.followRedirects,
            maxBufferedBytes: maxBufferedBytes, bufferObserver: bufferObserver
        )
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
        if sameOrigin {
            // URLSession drops Authorization on any redirect, so put the caller's headers back.
            var kept = proposed
            for (name, value) in original.allHTTPHeaderFields ?? [:] { kept.setValue(value, forHTTPHeaderField: name) }
            return kept
        }
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

/// Bounded hand-off from URLSession's callbacks to one reader. `append` blocks the delegate
/// queue while full, which holds back further deliveries; each fetch has its own queue, so
/// nothing else waits. `task.suspend()` was tried first and let loopback overshoot 20x.
final class BodyBuffer: @unchecked Sendable {
    private let highWater: Int
    private let condition = NSCondition()
    private var chunks: [Data] = []
    private var head = 0
    private var buffered = 0
    private var ended = false
    private var closed = false
    private var failure: Error?
    private var waiter: CheckedContinuation<Data?, Error>?

    init(highWater: Int) {
        self.highWater = highWater
    }

    /// Returns the buffered byte count. Data arriving after `close()` is discarded.
    @discardableResult
    func append(_ data: Data) -> Int {
        condition.lock()
        while buffered >= highWater, !closed, waiter == nil { condition.wait() }
        if closed {
            condition.unlock()
            return 0
        }
        if let reader = waiter {
            waiter = nil
            let count = buffered
            condition.unlock()
            reader.resume(returning: data)
            return count
        }
        chunks.append(data)
        buffered += data.count
        let count = buffered
        condition.unlock()
        return count
    }

    /// The reader went away: release a blocked `append`.
    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func finish(throwing error: Error?) {
        condition.lock()
        ended = true
        if failure == nil { failure = error }
        let reader = waiter
        waiter = nil
        condition.unlock()
        guard let reader else { return }
        if let error { reader.resume(throwing: error) } else { reader.resume(returning: nil) }
    }

    func next() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            condition.lock()
            if head < chunks.count {
                let data = chunks[head]
                chunks[head] = Data()
                head += 1
                if head == chunks.count {
                    chunks.removeAll(keepingCapacity: true)
                    head = 0
                }
                buffered -= data.count
                condition.broadcast()
                condition.unlock()
                continuation.resume(returning: data)
            } else if ended {
                let error = failure
                condition.unlock()
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: nil) }
            } else {
                waiter = continuation
                condition.broadcast()
                condition.unlock()
            }
        }
    }
}

/// Lives inside the body stream's closure, so dropping the stream cancels the request.
private final class BodyReader: Sendable {
    private let buffer: BodyBuffer
    private let task: URLSessionDataTask

    init(buffer: BodyBuffer, task: URLSessionDataTask) {
        self.buffer = buffer
        self.task = task
    }

    deinit {
        buffer.close()
        task.cancel()
    }

    func next() async throws -> Data? {
        let buffer = self.buffer
        let task = self.task
        return try await withTaskCancellationHandler {
            try await buffer.next()
        } onCancel: {
            buffer.close()
            task.cancel()
        }
    }
}

private final class FetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let original: URLRequest
    private let followRedirects: Bool
    private let maxBufferedBytes: Int
    private let bufferObserver: (@Sendable (Int) -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<FetchResponse, Error>?
    private var buffer: BodyBuffer?

    init(original: URLRequest, followRedirects: Bool, maxBufferedBytes: Int, bufferObserver: (@Sendable (Int) -> Void)?) {
        self.original = original
        self.followRedirects = followRedirects
        self.maxBufferedBytes = maxBufferedBytes
        self.bufferObserver = bufferObserver
    }

    func begin(_ continuation: CheckedContinuation<FetchResponse, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(followRedirects ? URLSessionTransport.redirectRequest(original: original, proposed: request) : nil)
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
        let body = BodyBuffer(highWater: maxBufferedBytes)
        let reader = BodyReader(buffer: body, task: dataTask)
        let stream = AsyncThrowingStream<Data, Error> { try await reader.next() }
        let waiting = lock.withLock { () -> CheckedContinuation<FetchResponse, Error>? in
            let waiting = continuation
            continuation = nil
            buffer = body
            return waiting
        }
        waiting?.resume(returning: FetchResponse(info: HTTPResponseInfo(statusCode: http.statusCode, headers: headers), body: stream))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let count = lock.withLock({ buffer })?.append(data) else { return }
        bufferObserver?(count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (waiting, body) = lock.withLock { () -> (CheckedContinuation<FetchResponse, Error>?, BodyBuffer?) in
            defer { continuation = nil; buffer = nil }
            return (continuation, buffer)
        }
        waiting?.resume(throwing: error ?? URLError(.badServerResponse))
        body?.finish(throwing: error)
        session.finishTasksAndInvalidate()
    }
}
