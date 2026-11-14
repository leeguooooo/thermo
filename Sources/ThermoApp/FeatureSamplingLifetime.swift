import Foundation

/// Timer callbacks run on a worker queue; lifetime changes and publication run
/// on the UI thread. A new visible session must reject an old session's result.
final class FeatureSamplingLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UUID?
    func start() -> UUID {
        lock.lock(); defer { lock.unlock() }
        let value = UUID(); token = value; return value
    }
    func stop() { lock.lock(); token = nil; lock.unlock() }
    func current() -> UUID? { lock.lock(); defer { lock.unlock() }; return token }
    func accepts(_ value: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return token == value }
}

