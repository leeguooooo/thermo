import Foundation

/// Read-only diagnosis of the AI agents on this Mac: Claude Code, Codex, Cursor and Gemini configuration
/// (hooks, MCP servers, plugins, skills, status line), their launchd jobs and their running processes.
/// Nothing is executed, started or killed; fixes are suggested as text.
public enum AgentDoctor {
    public static func run(_ env: DoctorEnvironment = DoctorEnvironment()) -> DoctorReport {
        var c = ConfigChecks(env: env)
        c.runAll()
        c.checkLaunchAgents()
        let (groups, sessions) = c.checkProcesses()
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
        return DoctorReport(generated: env.now, inventory: c.inventory, findings: findings, items: items, processes: groups, sessions: sessions)
    }
}

extension Severity {
    public var symbol: String { self == .error ? "✗" : self == .warning ? "!" : "·" }
}

extension DoctorReport {
    public var headline: String {
        let e = count(.error), w = count(.warning)
        if e + w == 0 { return "no problems found" }
        return [e > 0 ? "\(e) error\(e == 1 ? "" : "s")" : nil, w > 0 ? "\(w) warning\(w == 1 ? "" : "s")" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}
