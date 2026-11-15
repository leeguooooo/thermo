import Foundation

/// A feature may stop accepting work before a synchronous reader has returned.
/// Cancellation requests that stop; draining confirms the physical work is gone.
@MainActor package final class FeatureTasks {
    package init() {}
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var operations = Set<UUID>()
    package var hasOperations: Bool { !operations.isEmpty }
    package var count: Int { pending.count }
    package var enabled: () -> Bool = { true }
    package private(set) var stopping = false
    package var acceptsWork: Bool { !stopping && enabled() }

    @discardableResult
    package func run(priority: TaskPriority? = nil, onSkipped:@escaping @MainActor ()->Void = {}, operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        guard acceptsWork else { return Task {} }
        let id = UUID()
        let task = Task.detached(priority: priority) { [weak self] in
            let admitted=await self?.acceptsWork ?? false
            if !Task.isCancelled && admitted {await operation()}
            else {await onSkipped()}
            await self?.finished(id)
            return ()
        }
        pending[id] = task
        return task
    }
    @discardableResult
    package func runOnMain(operation:@escaping @MainActor () async -> Void)->Task<Void,Never> {
        guard acceptsWork else{return Task {}}
        let id=UUID()
        let task=Task { [weak self] in
            defer{self?.finished(id)}
            guard !Task.isCancelled,self?.acceptsWork == true else{return}
            await operation()
        }
        pending[id]=task;return task
    }
    package func beginOperation() -> UUID? {
        guard acceptsWork else {return nil}
        let id=UUID();operations.insert(id);return id
    }
    package func endOperation(_ id: UUID) {operations.remove(id)}
    private func finished(_ id: UUID) { pending[id] = nil }
    package func stop() { stopping = true; cancel() }
    package func cancel() { for task in pending.values { task.cancel() } }
    package func finish() async {
        while !pending.isEmpty || !operations.isEmpty {
            if let task=pending.values.first {await task.value}
            else {try? await Task.sleep(nanoseconds:20_000_000)}
        }
    }
}
