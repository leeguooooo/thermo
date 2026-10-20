import AgentDoctor
import AppKit
import SwiftUI
import ThermoL10n

// MARK: - Model

/// Runs the agent doctor and its actions off the main thread. A scan spawns ~1 launchctl per launch agent,
/// so it runs when the tab or window opens (if the last result is stale), on Rescan, and after an action.
@MainActor
final class AgentScanner: ObservableObject {
    let toolUsage = ToolUsageModel()
    let taskComparison = TaskComparisonModel()
    let mcpDefinitions: MCPDefinitionStore
    let mcpBatch: MCPBatchInspectionModel
    @Published private(set) var mcpBatchRunning = false
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
    @Published private(set) var stopped = false
    @Published private(set) var stopRequested = false
    @Published private(set) var tokenEncoding: TextEncoding = .heuristic
    @Published private(set) var project: URL?
    private let diagnose: (@Sendable () -> DoctorReport)?
    private let scanDiagnosis: @Sendable (DoctorCancellation, URL?, TextEncoding) -> DoctorReport
    private var scanCancellation: DoctorCancellation?
    private var operationLanguage: String?
    private var needsLanguageRefresh = false

    init(diagnose: (@Sendable () -> DoctorReport)? = nil, inspectMCP: MCPBatchInspectionModel.Inspector? = nil) {
        let store = MCPDefinitionStore()
        mcpDefinitions = store
        mcpBatch = MCPBatchInspectionModel(store: store, inspector: inspectMCP)
        self.diagnose = diagnose
        self.scanDiagnosis = { cancellation, project, encoding in
            diagnose?() ?? AgentDoctor.run(DoctorEnvironment(project: project, tokenEncoding: encoding, cancelled: { cancellation.isCancelled }))
        }
        mcpBatch.runningChanged = { [weak self] running in
            self?.mcpBatchRunning = running
            if !running { self?.resumeLanguageRefresh() }
        }
    }

    func selectEncoding(_ encoding: TextEncoding) {
        guard !busy else { return }
        tokenEncoding = encoding
        report = nil; selection = nil
        scan()
    }

    func selectProject(_ project: URL?) {
        guard !busy else { return }
        self.project = project?.standardizedFileURL
        report = nil
        selection = nil
        scan()
    }

    private func currentDiagnosis() -> @Sendable () -> DoctorReport {
        let project = project
        let custom = diagnose
        let encoding = tokenEncoding
        return { custom?() ?? AgentDoctor.run(DoctorEnvironment(project: project, tokenEncoding: encoding)) }
    }

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

    var busy: Bool { scanning || running != nil || batching || batch?.finished == false || mcpBatchRunning }

    func scan(ifOlderThan age: TimeInterval = 0) {
        if stopped && age > 0 { return }
        if busy {
            if let language = operationLanguage, language != L10n.current.rawValue { needsLanguageRefresh = true }
            return
        }
        if !stopped, let r = report, r.language == L10n.current.rawValue, Date().timeIntervalSince(r.generated) < age { return }
        mcpDefinitions.reset()
        let cancellation = DoctorCancellation()
        scanCancellation = cancellation
        scanning = true
        stopped = false
        stopRequested = false
        operationLanguage = L10n.current.rawValue
        needsLanguageRefresh = false
        let diagnose = scanDiagnosis
        let project = project
        let encoding = tokenEncoding
        Task.detached(priority: .userInitiated) {
            let r = diagnose(cancellation, project, encoding)
            await MainActor.run {
                guard self.scanCancellation === cancellation else { return }
                if cancellation.isCancelled || r.cancelled == true {
                    self.stopped = true
                    self.needsLanguageRefresh = false
                } else { self.acceptReport(r) }
                self.scanCancellation = nil
                self.stopRequested = false
                self.scanning = false
                self.resumeLanguageRefresh()
            }
        }
    }

    func stopScan() {
        guard scanning, let cancellation = scanCancellation else { return }
        stopRequested = true
        needsLanguageRefresh = false
        cancellation.cancel()
    }

    func perform(_ action: Action, on item: AgentItem) {
        guard !busy else { return }
        mcpDefinitions.reset()
        running = action.id
        operationLanguage = L10n.current.rawValue
        let diagnose = currentDiagnosis()
        Task.detached(priority: .userInitiated) {
            let result = ActionRunner.perform(action, env: DoctorEnvironment())
            let r = diagnose()
            await MainActor.run {
                self.recordResult(item: item.id, name: item.name, action: action.title, result: result)
                self.acceptReport(r)
                self.running = nil
                self.resumeLanguageRefresh()
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
        mcpDefinitions.reset()
        batching = true
        operationLanguage = L10n.current.rawValue
        let diagnose = currentDiagnosis()
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
            let r = rescan?() ?? diagnose()
            let failures = failed
            await MainActor.run {
                self.acceptReport(r)
                self.batch?.done = plans.count
                self.batch?.failed = failures
                self.batch?.after = r.items.filter(\.isProblem).count
                self.batch?.finished = true
                self.batching = false
                self.resumeLanguageRefresh()
            }
        }
    }
    private func acceptReport(_ result: DoctorReport) {
        if let language = result.language, language != L10n.current.rawValue {
            report = nil
            needsLanguageRefresh = true
        } else {
            report = result
            needsLanguageRefresh = false
        }
    }

    private func resumeLanguageRefresh() {
        if needsLanguageRefresh && !busy { scan() }
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
    /// Content evidence should lead to review; removal remains a separate choice.
    var primaryDiagnosticAction: Action? {
        if let fix = actions.first(where: { $0.kind == .fix }) { return fix }
        if let update = actions.first(where: { $0.kind == .update }) { return update }
        return area == .skills ? nil : actions.first
    }
}
