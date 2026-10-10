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

    struct Batch {
        var total: Int
        var done = 0
        var failed = 0
        var current = ""
        var finished = false
        var before = 0
        var after = 0
    }

    struct LastResult {
        var item: AgentItem.ID
        var action: String
        var result: ActionResult
    }

    func scan(ifOlderThan age: TimeInterval = 0) {
        if scanning { return }
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
        guard running == nil else { return }
        running = action.id
        Task.detached(priority: .userInitiated) {
            let result = ActionRunner.perform(action, env: DoctorEnvironment())
            let r = AgentDoctor.run()
            await MainActor.run {
                self.lastResult = LastResult(item: item.id, action: action.title, result: result)
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
    func performAll(_ plans: [(AgentItem, Action)]) {
        guard batch?.finished != false, running == nil, !plans.isEmpty else { return }
        batch = Batch(total: plans.count, before: problems.count)
        Task.detached(priority: .userInitiated) {
            let env = DoctorEnvironment()
            var failed = 0
            for (i, (item, action)) in plans.enumerated() {
                await MainActor.run { self.batch?.current = item.name; self.batch?.done = i }
                if !ActionRunner.perform(action, env: env).ok { failed += 1 }
            }
            let r = AgentDoctor.run()
            let failures = failed
            await MainActor.run {
                self.report = r
                self.batch?.done = plans.count
                self.batch?.failed = failures
                self.batch?.after = r.items.filter(\.isProblem).count
                self.batch?.finished = true
            }
        }
    }
}

extension AgentItem {
    var isProblem: Bool { severity == .error || severity == .warning }
}
