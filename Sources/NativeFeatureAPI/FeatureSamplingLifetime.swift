import Foundation

/// Timer callbacks run on a worker queue; lifetime changes and publication run
/// on the UI thread. A new visible session must reject an old session's result.
package final class FeatureSamplingLifetime: @unchecked Sendable {
    package init(){}
    private let lock = NSLock()
    private var token: UUID?
    package func start() -> UUID {
        lock.lock(); defer { lock.unlock() }
        let value = UUID(); token = value; return value
    }
    package func stop() { lock.lock(); token = nil; lock.unlock() }
    package func current() -> UUID? { lock.lock(); defer { lock.unlock() }; return token }
    package func accepts(_ value: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return token == value }
}

