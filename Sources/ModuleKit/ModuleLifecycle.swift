import Foundation

/// When one module's process runs. Pure: the kernel feeds it events with the current time and does
/// what it answers (`start`, `stop`) and wakes it again at `deadline`. Nothing here touches a process.
///
/// - An `onDemand` module runs while something uses it (an attached scene, a command in flight) and
///   is stopped `idleTimeout` after the last use ended.
/// - `prewarm` and `always` modules run whenever they are on.
/// - A process that exits without being asked to is a crash: the next start waits, twice as long
///   after each crash in a row. A run of `stableRun` forgets the earlier crashes.
/// - `suspendAfter` crashes in a row switch the module off and mark it `suspended`, so one broken module
///   stops costing restarts; the person switches it on again once an update or a fix is in.
/// - A module that is off has no process and nothing scheduled.
public struct ModuleLifecycle: Sendable, Equatable {
    public enum Phase: String, Sendable {
        /// No process.
        case stopped
        /// The kernel was told to start it and has not answered yet.
        case starting
        case running
        /// The kernel was told to stop it and the process has not exited yet.
        case stopping
        /// No process; a start is due at `deadline` (after a crash).
        case waiting
    }

    public enum Event: Sendable, Equatable {
        case enable, disable
        /// One more user of the module: a scene was attached, a command began.
        case acquire
        /// That use ended.
        case release
        /// The process is up.
        case started
        /// The process could not be started.
        case startFailed
        /// The process is gone, asked or not.
        case exited
        /// `deadline` has passed.
        case tick
    }

    public enum Effect: Sendable, Equatable { case start, stop }

    public struct Timing: Sendable, Equatable {
        public var idleTimeout: TimeInterval
        /// Wait before the first restart; doubled for each further crash in a row.
        public var firstBackoff: TimeInterval
        public var longestBackoff: TimeInterval
        /// A process that lived this long did not crash because of how it was started.
        public var stableRun: TimeInterval
        /// Crashes in a row after which the module is switched off.
        public var suspendAfter: Int
        public init(idleTimeout: TimeInterval = 120, firstBackoff: TimeInterval = 1, longestBackoff: TimeInterval = 300, stableRun: TimeInterval = 60, suspendAfter: Int = 5) {
            self.idleTimeout = idleTimeout; self.firstBackoff = firstBackoff; self.longestBackoff = longestBackoff; self.stableRun = stableRun
            self.suspendAfter = max(1, suspendAfter)
        }
    }

    public let launch: ModuleManifest.Launch
    public var timing: Timing
    public private(set) var enabled: Bool
    public private(set) var phase = Phase.stopped
    /// Attached scenes plus commands in flight.
    public private(set) var uses = 0
    /// Crashes in a row.
    public private(set) var crashes = 0
    /// Switched off by `suspendAfter` crashes in a row rather than by the person. Cleared by `enable`.
    public private(set) var suspended = false
    /// When the kernel must send `tick`, if at all. `nil` means nothing is scheduled.
    public private(set) var deadline: TimeInterval?
    private var startedAt: TimeInterval?
    /// No start before this, even when asked: the backoff outlives an on-demand module's use.
    private var retryAt: TimeInterval?

    public init(launch: ModuleManifest.Launch, enabled: Bool = false, timing: Timing = Timing()) {
        self.launch = launch; self.enabled = enabled; self.timing = timing
    }

    /// Whether a process is wanted right now.
    public var wanted: Bool { enabled && (launch != .onDemand || uses > 0) }

    public func backoff(after crashes: Int) -> TimeInterval {
        guard crashes > 0 else { return 0 }
        return min(timing.longestBackoff, timing.firstBackoff * pow(2, Double(min(crashes, 30) - 1)))
    }

    public mutating func handle(_ event: Event, now: TimeInterval) -> [Effect] {
        switch event {
        case .enable:
            guard !enabled else { return [] }
            enabled = true; suspended = false; crashes = 0
            return settle(now)
        case .disable:
            guard enabled else { return [] }
            enabled = false; crashes = 0; retryAt = nil; deadline = nil
            switch phase {
            case .running: idleSince = nil; phase = .stopping; return [.stop]
            case .waiting: phase = .stopped; return []
            // A start in flight is stopped when it answers; see `started`.
            case .starting, .stopping, .stopped: return []
            }
        case .acquire:
            uses += 1
            return settle(now)
        case .release:
            uses = max(0, uses - 1)
            return settle(now)
        case .started:
            guard phase == .starting else { return [] }
            phase = .running; startedAt = now; idleSince = nil
            return settle(now)
        case .startFailed:
            guard phase == .starting else { return [] }
            return crashed(now)
        case .exited:
            switch phase {
            case .stopping:
                phase = .stopped; startedAt = nil
                return settle(now)
            case .running, .starting:
                return crashed(now)
            case .stopped, .waiting: return []
            }
        case .tick:
            guard let due = deadline, now >= due else { return [] }
            deadline = nil
            return settle(now)
        }
    }

    private mutating func crashed(_ now: TimeInterval) -> [Effect] {
        if let began = startedAt, now - began >= timing.stableRun { crashes = 0 }
        startedAt = nil; idleSince = nil; phase = .stopped
        // Switched off while it was starting or just before it died: nothing to hold against it.
        guard enabled else { crashes = 0; retryAt = nil; return settle(now) }
        crashes += 1
        if crashes >= timing.suspendAfter {
            enabled = false; suspended = true; retryAt = nil
            return settle(now)
        }
        retryAt = now + backoff(after: crashes)
        return settle(now)
    }

    /// Moves toward what is wanted and sets the one deadline that matters next.
    private mutating func settle(_ now: TimeInterval) -> [Effect] {
        deadline = nil
        switch phase {
        case .stopped, .waiting:
            guard wanted else { phase = .stopped; return [] }
            if let retry = retryAt, now < retry { phase = .waiting; deadline = retry; return [] }
            retryAt = nil; phase = .starting
            return [.start]
        case .starting, .stopping:
            return []
        case .running:
            if !enabled { phase = .stopping; return [.stop] }
            guard launch == .onDemand, uses == 0 else { idleSince = nil; return [] }
            let since = idleSince ?? now
            idleSince = since
            if now >= since + timing.idleTimeout { idleSince = nil; phase = .stopping; return [.stop] }
            deadline = since + timing.idleTimeout
            return []
        }
    }

    /// When the last use of a running on-demand module ended.
    private var idleSince: TimeInterval?
}
