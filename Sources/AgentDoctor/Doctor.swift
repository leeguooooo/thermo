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
        return DoctorReport(generated: env.now, inventory: c.inventory, findings: findings, processes: groups, sessions: sessions)
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
