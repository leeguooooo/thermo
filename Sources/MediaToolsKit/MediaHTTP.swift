import Foundation

public struct MediaRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct MediaResponse: Sendable {
    public var statusCode: Int
    /// The URL after redirects; the FFmpeg checksum sidecar sits next to it, not next to the redirect.
    public var finalURL: URL
    public var body: AsyncThrowingStream<Data, Error>

    public init(statusCode: Int, finalURL: URL, body: AsyncThrowingStream<Data, Error>) {
        self.statusCode = statusCode
        self.finalURL = finalURL
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }

    func collect(limit: Int) async throws -> Data {
        var data = Data()
        for try await chunk in body {
            data.append(chunk)
            if data.count > limit { throw MediaToolsError.responseTooLarge }
        }
        return data
    }
}

/// DownloadKit's transport has no method, body or final URL, which Gopeed and the sidecar both need.
public protocol MediaHTTPTransport: Sendable {
    func send(_ request: MediaRequest) async throws -> MediaResponse
}

public struct URLSessionMediaTransport: MediaHTTPTransport {
    private let bypassProxy: Bool
    private let requestTimeout: TimeInterval

    /// For public downloads; follows the system proxy.
    public static let internet = URLSessionMediaTransport(bypassProxy: false, requestTimeout: 60)
    /// For 127.0.0.1 only: a configured proxy must never see local engine traffic.
    public static let loopback = URLSessionMediaTransport(bypassProxy: true, requestTimeout: 30)

    public func send(_ request: MediaRequest) async throws -> MediaResponse {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.httpShouldHandleCookies = false
        request.headers.forEach { urlRequest.setValue($0.value, forHTTPHeaderField: $0.key) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        if bypassProxy { configuration.connectionProxyDictionary = [:] }
        let delegate = MediaFetchDelegate()
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
}

private final class MediaFetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MediaResponse, Error>?
    private var body: AsyncThrowingStream<Data, Error>.Continuation?

    func begin(_ continuation: CheckedContinuation<MediaResponse, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let downgrade = response.url?.scheme?.lowercased() == "https" && request.url?.scheme?.lowercased() != "https"
        completionHandler(downgrade ? nil : request)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, let url = http.url else {
            completionHandler(.cancel)
            return
        }
        let (stream, streamContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        streamContinuation.onTermination = { termination in
            if case .cancelled = termination { dataTask.cancel() }
        }
        let waiting = lock.withLock { () -> CheckedContinuation<MediaResponse, Error>? in
            let waiting = continuation
            continuation = nil
            body = streamContinuation
            return waiting
        }
        waiting?.resume(returning: MediaResponse(statusCode: http.statusCode, finalURL: url, body: stream))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        _ = lock.withLock { body }?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (waiting, stream) = lock.withLock { () -> (CheckedContinuation<MediaResponse, Error>?, AsyncThrowingStream<Data, Error>.Continuation?) in
            defer { continuation = nil; body = nil }
            return (continuation, body)
        }
        waiting?.resume(throwing: error ?? URLError(.badServerResponse))
        stream?.finish(throwing: error)
        session.finishTasksAndInvalidate()
    }
}
