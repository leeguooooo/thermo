import AgentDoctor
import AppKit
import SwiftUI
import ThermoL10n

// MARK: - Model

/// Runs the agent doctor and its actions off the main thread. A scan spawns ~1 launchctl per launch agent,
/// so it runs when the tab or window opens (if the last result is stale), on Rescan, and after an action.
@MainActor
final class AgentScanner: ObservableObject {
    @Published var report: DoctorReport?
    @Published var scanning = false
    /// The item the diagnostics window shows.
    @Published var selection: AgentItem.ID?
    /// Result of the last action, shown on the item it ran on.
    @Published var lastResult: LastResult?
    @Published var running: Action.ID?
    /// A batch of fixes in progress ("Fixing 3 of 9: …") and, afterwards, what it achieved.
    @Published var batch: Batch?
    @Published private(set) var batching = false
    @Published private(set) var history: [LastResult] = []

    struct Batch {
        var total: Int
        var done = 0
        var failed = 0
        var current = ""
        var finished = false
        var before = 0
        var after = 0
        var results: [LastResult] = []
        var verifying = false
    }

    struct LastResult: Identifiable {
        var id = UUID()
        var time = Date()
        var name: String
        var item: AgentItem.ID
        var action: String
        var result: ActionResult
    }

    var busy: Bool { scanning || running != nil || batching || batch?.finished == false }

    func scan(ifOlderThan age: TimeInterval = 0) {
        if busy { return }
        if let r = report, Date().timeIntervalSince(r.generated) < age { return }
        scanning = true
        Task.detached(priority: .userInitiated) {
            let r = AgentDoctor.run()
            await MainActor.run {
                self.report = r
                self.scanning = false
            }
        }
    }

    func perform(_ action: Action, on item: AgentItem) {
        guard !busy else { return }
        running = action.id
        Task.detached(priority: .userInitiated) {
            let result = ActionRunner.perform(action, env: DoctorEnvironment())
            let r = AgentDoctor.run()
            await MainActor.run {
                self.recordResult(item: item.id, name: item.name, action: action.title, result: result)
                self.report = r
                self.running = nil
            }
        }
    }

    var problems: [AgentItem] { report?.items.filter(\.isProblem) ?? [] }

    /// The safe automatic fix of every problem item: what "Fix all" runs.
    var bulkFixes: [(AgentItem, Action)] {
        problems.compactMap { item in item.actions.first { $0.kind == .fix && $0.bulk }.map { (item, $0) } }
    }

    /// Runs fixes one after another, reporting progress, then rescans and records how many problems are left.
    func performAll(_ plans: [(AgentItem, Action)],
                    executor: (@Sendable (Action) -> ActionResult)? = nil,
                    rescan: (@Sendable () -> DoctorReport)? = nil) {
        guard !busy, !plans.isEmpty else { return }
        batching = true
        batch = Batch(total: plans.count, before: problems.count)
        Task.detached(priority: .userInitiated) {
            let env = DoctorEnvironment()
            var failed = 0
            for (i, (item, action)) in plans.enumerated() {
                await MainActor.run { self.batch?.current = item.name; self.batch?.done = i }
                let result = executor?(action) ?? ActionRunner.perform(action, env: env)
                if !result.ok { failed += 1 }
                await MainActor.run {
                    let entry = self.recordResult(item: item.id, name: item.name, action: action.title, result: result)
                    self.batch?.results.append(entry)
                    self.batch?.done = i + 1
                }
            }
            await MainActor.run { self.batch?.verifying = true }
            let r = rescan?() ?? AgentDoctor.run()
            let failures = failed
            await MainActor.run {
                self.report = r
                self.batch?.done = plans.count
                self.batch?.failed = failures
                self.batch?.after = r.items.filter(\.isProblem).count
                self.batch?.finished = true
                self.batching = false
            }
        }
    }
    @discardableResult
    func recordResult(item: String, name: String, action: String, result: ActionResult) -> LastResult {
        var backupPaths = Set<String>()
        let safe = ActionResult(ok: result.ok,
                                log: result.log.map { String(Redact.text($0).prefix(4000)) },
                                backups: result.backups.map(Redact.text).filter { backupPaths.insert($0).inserted })
        let entry = LastResult(name: Redact.text(name), item: item, action: Redact.text(action), result: safe)
        lastResult = entry
        history.insert(entry, at: 0)
        if history.count > 20 { history.removeLast(history.count - 20) }
        return entry
    }

}

extension AgentItem {
    var isProblem: Bool { severity == .error || severity == .warning }
}
