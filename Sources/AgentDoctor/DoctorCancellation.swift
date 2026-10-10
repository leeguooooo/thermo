import Foundation

public final class DoctorCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
    }
}
