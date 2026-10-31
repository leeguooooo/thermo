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
    /// Asked for a new link when the current one looks expired.
    public var refreshLink: LinkRefresher?

    public init(
        url: URL, destination: URL, headers: [String: String] = [:], cookies: [DownloadCookie] = [],
        refreshLink: LinkRefresher? = nil
    ) {
        self.url = url
        self.destination = destination
        self.headers = headers
        self.cookies = cookies
        self.refreshLink = refreshLink
    }
}

/// Why a new link is needed. `url` has its query removed, so it is safe to show or log.
public struct LinkExpiry: Sendable, Equatable {
    public var taskID: UUID
    public var url: URL
    /// nil when the task was restored without its link, or the server sent an HTML page.
    public var statusCode: Int?
}

public struct RefreshedLink: Sendable {
    public var url: URL
    /// Replaces the task's headers when set; kept in memory only.
    public var headers: [String: String]?

    public init(url: URL, headers: [String: String]? = nil) {
        self.url = url
        self.headers = headers
    }
}

/// Returns a fresh link, or nil when there is none. Called by one worker at a time.
public typealias LinkRefresher = @Sendable (LinkExpiry) async throws -> RefreshedLink?

/// Slow-connection replacement, with YunX's `DownloadTuning` defaults and watchdog constants.
public struct PreemptionPolicy: Sendable, Equatable {
    public var isEnabled = true
    public var minBytesPerSecond: Int64 = 12 * 1024
    public var minAge: TimeInterval = 15
    public var tick: TimeInterval = 5
    public var cooldown: TimeInterval = 10
    public var minRemaining: Int64 = 128 * 1024
    public var maxPerSegment = 3
    public var maxPerTick = 2
    public var endgameInflight = 3
    public var endgameMinAge: TimeInterval = 3

    public init() {}

    /// Per-CDN relative threshold; the absolute floor covers a lone connection dragging its own average down.
    public func floorBytesPerSecond(averagePerConnection: Int64) -> Int64 {
        max(minBytesPerSecond, averagePerConnection / 2)
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
    public var preemption: PreemptionPolicy
    /// Link refreshes allowed in a row without a byte arriving.
    public var maxLinkRefreshes: Int
    /// Shared bandwidth cap. Pass one instance to every engine to cap them together.
    public var speedLimiter: DownloadSpeedLimiter?

    public init(
        concurrency: Int = 4,
        minimumSegmentSize: Int64 = 1 << 20,
        maxRetries: Int = 4,
        baseRetryDelay: Duration = .milliseconds(500),
        maxRetryDelay: Duration = .seconds(30),
        progressInterval: TimeInterval = 0.2,
        speedWindow: TimeInterval = 5,
        preemption: PreemptionPolicy = PreemptionPolicy(),
        maxLinkRefreshes: Int = 3,
        speedLimiter: DownloadSpeedLimiter? = nil
    ) {
        self.concurrency = max(1, concurrency)
        self.minimumSegmentSize = max(1, minimumSegmentSize)
        self.maxRetries = max(0, maxRetries)
        self.baseRetryDelay = baseRetryDelay
        self.maxRetryDelay = maxRetryDelay
        self.progressInterval = progressInterval
        self.speedWindow = speedWindow
        self.preemption = preemption
        self.maxLinkRefreshes = max(0, maxLinkRefreshes)
        self.speedLimiter = speedLimiter
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
    case contentRangeMismatch
    case htmlResponse
    case linkExpired
    case linkRequired
    case corruptPart(segment: Int)
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
        case .contentRangeMismatch: return "content-range does not match the request"
        case .htmlResponse: return "server returned an html page; the link may have expired or need a referer"
        case .linkExpired: return "the download link has expired"
        case .linkRequired: return "the saved link was not stored; pass the url again"
        case .corruptPart(let segment): return "part \(segment) failed its hash check"
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
