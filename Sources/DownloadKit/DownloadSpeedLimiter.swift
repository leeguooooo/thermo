import Foundation

/// Token bucket shared by every connection that holds it. The limit is read on each call, so
/// a settings change applies at once; 0 means unlimited.
public final class DownloadSpeedLimiter: @unchecked Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let limit: @Sendable () -> Int64
    private let clock: @Sendable () -> TimeInterval
    private let sleep: Sleep
    private let lock = NSLock()
    /// Fractional, or the slivers lost on each short wait would add up to a lower rate.
    private var tokens = 0.0
    private var lastRefill: TimeInterval?

    public convenience init(limit: @escaping @Sendable () -> Int64) {
        self.init(limit: limit, clock: { ProcessInfo.processInfo.systemUptime }, sleep: { try await Task.sleep(for: $0) })
    }

    init(limit: @escaping @Sendable () -> Int64, clock: @escaping @Sendable () -> TimeInterval, sleep: @escaping Sleep) {
        self.limit = limit
        self.clock = clock
        self.sleep = sleep
    }

    /// Waits until `bytes` may pass. The bucket holds one second's worth, so a request larger
    /// than that is taken in pieces; taken whole it could never be satisfied.
    public func acquire(_ bytes: Int64) async throws {
        var left = bytes
        while left > 0 {
            let rate = limit()
            guard rate > 0 else { return }
            let piece = min(left, rate)
            let waitMilliseconds: Int64 = lock.withLock {
                refill(rate)
                if Double(piece) <= tokens {
                    tokens -= Double(piece)
                    return 0
                }
                let deficit = (Double(piece) - tokens) * 1000 / Double(rate)
                return min(max(Int64(deficit.rounded(.up)), 1), 200)
            }
            if waitMilliseconds == 0 {
                left -= piece
            } else {
                try await sleep(.milliseconds(waitMilliseconds))
            }
        }
    }

    private func refill(_ rate: Int64) {
        let now = clock()
        defer { lastRefill = now }
        guard let lastRefill else { return }
        tokens = min(Double(rate), tokens + max(0, now - lastRefill) * Double(rate))
    }
}
