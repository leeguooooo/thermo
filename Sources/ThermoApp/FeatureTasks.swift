import Foundation

/// A feature may stop accepting work before a synchronous reader has returned.
/// Cancellation requests that stop; draining confirms the physical work is gone.
@MainActor final class FeatureTasks {
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var operations = Set<UUID>()
    var hasOperations: Bool { !operations.isEmpty }
    var count: Int { pending.count }
    var enabled: () -> Bool = { true }
    private(set) var stopping = false
    var acceptsWork: Bool { !stopping && enabled() }

    @discardableResult
    func run(priority: TaskPriority? = nil, operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        guard acceptsWork else { return Task {} }
        let id = UUID()
        let task = Task.detached(priority: priority) { [weak self] in
            await operation()
            await self?.finished(id)
            return ()
        }
        pending[id] = task
        return task
    }
    func beginOperation() -> UUID? {
        guard acceptsWork else {return nil}
        let id=UUID();operations.insert(id);return id
    }
    func endOperation(_ id: UUID) {operations.remove(id)}
    private func finished(_ id: UUID) { pending[id] = nil }
    func stop() { stopping = true; cancel() }
    func cancel() { for task in pending.values { task.cancel() } }
    func finish() async {
        while !pending.isEmpty || !operations.isEmpty {
            if let task=pending.values.first {await task.value}
            else {try? await Task.sleep(nanoseconds:20_000_000)}
        }
    }
}
