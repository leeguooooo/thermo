import Foundation

/// A name/value cookie sent with one task. Kept in memory only, never persisted.
public struct DownloadCookie: Sendable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct DownloadRequest: Sendable {
    public var url: URL
    public var destination: URL
    public var headers: [String: String]
    public var cookies: [DownloadCookie]

    public init(url: URL, destination: URL, headers: [String: String] = [:], cookies: [DownloadCookie] = []) {
        self.url = url
        self.destination = destination
        self.headers = headers
        self.cookies = cookies
    }
}

public struct DownloadConfiguration: Sendable {
    /// Maximum simultaneous Range connections for one task.
    public var concurrency: Int
    /// Smallest segment the planner or the re-splitter will create.
    public var minimumSegmentSize: Int64
    /// Failed attempts allowed after the first, counted since the segment last made progress.
    public var maxRetries: Int
    public var baseRetryDelay: Duration
    public var maxRetryDelay: Duration
    /// Minimum seconds between progress events.
    public var progressInterval: TimeInterval
    /// Seconds of history behind the reported speed.
    public var speedWindow: TimeInterval

    public init(
        concurrency: Int = 4,
        minimumSegmentSize: Int64 = 1 << 20,
        maxRetries: Int = 4,
        baseRetryDelay: Duration = .milliseconds(500),
        maxRetryDelay: Duration = .seconds(30),
        progressInterval: TimeInterval = 0.2,
        speedWindow: TimeInterval = 5
    ) {
        self.concurrency = max(1, concurrency)
        self.minimumSegmentSize = max(1, minimumSegmentSize)
        self.maxRetries = max(0, maxRetries)
        self.baseRetryDelay = baseRetryDelay
        self.maxRetryDelay = maxRetryDelay
        self.progressInterval = progressInterval
        self.speedWindow = speedWindow
    }
}

public enum DownloadPhase: Sendable, Equatable {
    case probing, downloading, merging, paused, cancelled
    case completed(URL)
    case failed(String)
}

public struct DownloadProgress: Sendable, Equatable {
    public var id: UUID
    public var phase: DownloadPhase
    public var receivedBytes: Int64
    public var totalBytes: Int64?
    public var bytesPerSecond: Double
    public var activeSegments: Int
}

public enum DownloadError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedURL(String)
    case invalidHeader(String)
    case httpStatus(Int)
    case rangeNotHonored
    case remoteChanged
    case retriesExhausted(attempts: Int, lastError: String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case incompleteData(gap: Range<Int64>)
    case stateNotFound(UUID)
    case stateCorrupt(String)
    case io(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedURL(let why): return "unsupported url: \(why)"
        case .invalidHeader(let name): return "invalid header: \(name)"
        case .httpStatus(let code): return "server returned http \(code)"
        case .rangeNotHonored: return "server did not honor the requested range"
        case .remoteChanged: return "remote file changed during the download"
        case .retriesExhausted(let attempts, let last): return "gave up after \(attempts) attempts: \(last)"
        case .sizeMismatch(let expected, let actual): return "size mismatch: expected \(expected) bytes, got \(actual)"
        case .incompleteData(let gap): return "incomplete data: missing bytes \(gap.lowerBound)..<\(gap.upperBound)"
        case .stateNotFound(let id): return "no saved download \(id.uuidString)"
        case .stateCorrupt(let why): return "saved download is corrupt: \(why)"
        case .io(let why): return "file error: \(why)"
        case .cancelled: return "download cancelled"
        }
    }
}
