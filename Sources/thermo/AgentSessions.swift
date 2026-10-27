import CleanKit
import Foundation

/// `thermo agents sessions`: each agent session with the MCP servers it runs, idle ones first.
extension AgentsCommand {
    func sessions(_ rest: [String]) throws {
        guard rest.count == 1 else { throw CLIError("usage: thermo agents sessions [--json]") }
        let groups = AgentSessionGroup.group(SlowdownSampler().sample(window: 0.5))
        if app.args.has("json") { print(Export.json(groups)); return }
        let style = app.style
        for g in groups {
            let when = g.lastActivity.map { tr("last active %1$@ ago", MemorySuspects.duration(Date().timeIntervalSince($0))) } ?? tr("no transcript activity found")
            let head = [g.title, g.pid.map { "PID \($0)" }, g.cwd].compactMap { $0 }.joined(separator: " · ")
            let state = g.idle ? style.yellow(tr("idle")) : g.lastActivity == nil ? style.dim(tr("unknown")) : style.green(tr("active"))
            print(state + " " + style.bold(head)
                  + style.dim("  " + MemoryFormat.string(kibibytes: g.memoryKB) + " · " + when))
            for s in g.servers {
                print("   " + "\(s.name) ×\(s.pids.count)  " + style.dim(MemoryFormat.string(kibibytes: s.memoryKB) + " · PID " + s.pids.prefix(8).map(String.init).joined(separator: ", ") + (s.pids.count > 8 ? "…" : "")))
            }
        }
        let idleKB = groups.filter(\.idle).reduce(0) { $0 + $1.mcpMemoryKB }
        print("")
        print(tr("MCP servers of idle sessions use %1$@. thermo pulse why lists the ones that are safe to end.", MemoryFormat.string(kibibytes: idleKB)))
    }
}
