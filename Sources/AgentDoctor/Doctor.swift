import Foundation
import ThermoL10n

/// Read-only diagnosis of the AI agents on this Mac: Claude Code, Codex, Cursor and Gemini configuration
/// (hooks, MCP servers, plugins, skills, status line), their launchd jobs and their running processes.
/// Only read-only system queries run; diagnosis never stops user processes or applies fixes.
public enum AgentDoctor {
    public static func run(_ env: DoctorEnvironment = DoctorEnvironment()) -> DoctorReport {
        let language = L10n.current.rawValue
        var c = ConfigChecks(env: env)
        if !env.cancelled() { c.runAll() }
        if !env.cancelled() { c.checkLaunchAgents() }
        if !env.cancelled() { c.checkCrashes() }
        let (groups, sessions): ([ProcessGroup], Int) = env.cancelled() ? ([], 0) : c.checkProcesses()
        if env.cancelled() {
            var stopped = DoctorReport(generated: env.now, inventory: Inventory(), findings: [], items: [], processes: [], sessions: 0)
            stopped.language = language
            stopped.cancelled = true
            return stopped
        }
        let order = Dictionary(uniqueKeysWithValues: Area.allCases.enumerated().map { ($1, $0) })
        let findings = c.findings.enumerated().sorted { a, b in
            (a.element.severity, order[a.element.area]!, a.offset) < (b.element.severity, order[b.element.area]!, b.offset)
        }.map(\.element)
        // Each item takes the worst severity of its findings.
        var items = c.items
        var worst: [String: Severity] = [:]
        for f in findings { if let id = f.item { worst[id] = min(worst[id] ?? .info, f.severity) } }
        for i in items.indices { items[i].severity = worst[items[i].id] }
        // Problems, then notes, then healthy, then switched off.
        let rank = { (i: AgentItem) in i.severity?.rank ?? (i.enabled ? 3 : 4) }
        items = items.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            if order[x.area]! != order[y.area]! { return order[x.area]! < order[y.area]! }
            if rank(x) != rank(y) { return rank(x) < rank(y) }
            return a.offset < b.offset
        }.map(\.element)
        var report = DoctorReport(generated: env.now, inventory: c.inventory, findings: findings, items: items, processes: groups, sessions: sessions)
        report.language = language
        report.cancelled = env.cancelled() ? true : nil
        return report
    }
}

extension Severity {
    public var symbol: String { self == .error ? "✗" : self == .warning ? "!" : "·" }
}

extension DoctorReport {
    public var headline: String {
        if cancelled == true { return tr("check stopped") }
        if !hasResults { return tr("no agent items found") }
        let e = count(.error), w = count(.warning)
        if e + w == 0 { return tr("no problems found") }
        let errors = e == 1 ? tr("1 error") : tr("%1$@ errors", String(e))
        let warnings = w == 1 ? tr("1 warning") : tr("%1$@ warnings", String(w))
        return [e > 0 ? errors : nil, w > 0 ? warnings : nil]
            .compactMap { $0 }.joined(separator: tr(", "))
    }
}
