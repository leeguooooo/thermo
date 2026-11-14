import Foundation

/// A feature may stop accepting work before a synchronous reader has returned.
/// Cancellation requests that stop; draining confirms the physical work is gone.
@MainActor final class FeatureTasks {
    private var pending: [UUID: Task<Void, Never>] = [:]
    var count: Int { pending.count }

    @discardableResult
    func run(priority: TaskPriority? = nil, operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task.detached(priority: priority) { [weak self] in
            await operation()
            await self?.finished(id)
        }
        pending[id] = task
        return task
    }
    private func finished(_ id: UUID) { pending[id] = nil }
    func cancel() { for task in pending.values { task.cancel() } }
    func finish() async {
        while let task = pending.values.first { await task.value }
    }
}
