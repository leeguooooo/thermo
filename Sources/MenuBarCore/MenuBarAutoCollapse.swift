import Foundation

public enum MenuBarAutoCollapseDelay: Int, CaseIterable, Hashable, Sendable {
    case disabled = 0
    case tenSeconds = 10
    case thirtySeconds = 30
    case oneMinute = 60

    public var nanoseconds: UInt64? {
        self == .disabled ? nil : UInt64(rawValue) * 1_000_000_000
    }
}

/// A one-shot deadline. Cancelled or replaced tasks cannot collapse a newer
/// reveal request, even if cancellation races with the sleep completing.
@MainActor public final class MenuBarAutoCollapse {
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    public var isScheduled: Bool { task != nil }

    public init() {}

    public func schedule(after nanoseconds: UInt64, action: @escaping @MainActor () -> Void) {
        cancel()
        let request = generation
        task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
            guard let self, self.generation == request else { return }
            self.task = nil
            action()
        }
    }

    public func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
