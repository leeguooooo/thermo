import AgentCore
import CleanKit
import Foundation

/// `thermo pulse tools` and `thermo pulse rescue`: the MCP servers and helpers AI agents keep, per
/// host, and the emergency that ends the left-behind ones in one go. Neither reads transcripts or
/// asks a model, so both answer on a machine that is already swapping.
extension PulseCommand {
    private struct ToolsReport: Encodable {
        var groups: [ToolProcessGroup]
        var memoryKB: Int
        var rescueKB: Int
        var rescueProcesses: Int
    }

    private func toolGroups() -> ([ToolProcessGroup], [SlowdownProcess]) {
        let processes = SlowdownSampler().sample(window: 1)
        return (ToolProcesses.inventory(processes), processes)
    }

    private func host(_ s: ToolProcesses.Summary) -> String {
        switch s.hostKind {
        case .none: return tr("starter has exited")
        case .sharedService: return tr("held by %1$@ (PID %2$@)", s.hostName, s.groups.compactMap(\.hostPID).map(String.init).joined(separator: ", "))
        case .session: return trCount(s.hosts, "in %1$@ %2$@ session", "in %1$@ %2$@ sessions", s.hostName)
        }
    }

    func tools(_ rest: [String]) throws {
        guard rest.isEmpty else { throw CLIError("usage: thermo pulse tools [--json]") }
        let (groups, _) = toolGroups()
        let rescue = ToolProcesses.rescueIdentities(groups)
        if app.args.has("json") {
            print(Export.json(ToolsReport(groups: groups, memoryKB: groups.reduce(0) { $0 + $1.memoryKB },
                                          rescueKB: groups.reduce(0) { $0 + $1.rescueKB }, rescueProcesses: rescue.count)))
            return
        }
        let style = app.style
        guard !groups.isEmpty else { print(tr("No tool processes of AI agents are running.")); return }
        print(style.bold(tr("Tool processes kept by AI agents: %1$@ in %2$@ processes.",
                            Self.size(groups.reduce(0) { $0 + $1.memoryKB }), String(groups.reduce(0) { $0 + $1.processes }))))
        for g in ToolProcesses.summary(groups) {
            let left = g.rescueCopies
            print("  " + style.bold(g.name) + " ×\(g.copies)  " + Self.size(g.memoryKB) + style.dim("  " + host(g) + "  " + tr("oldest %1$@", Self.duration(g.oldest)))
                  + (left > 0 ? "  " + style.yellow(tr("%1$@ left behind (%2$@)", String(left), Self.size(g.rescueKB))) : ""))
        }
        if !rescue.isEmpty {
            print("")
            print(style.cyan("→ thermo pulse rescue") + style.dim("  " + tr("ends the %1$@ left-behind processes (about %2$@); no session or app is closed.",
                                                                      String(rescue.count), Self.size(groups.reduce(0) { $0 + $1.rescueKB }))))
        }
    }

    func rescue(_ rest: [String]) throws {
        guard rest.isEmpty else { throw CLIError("usage: thermo pulse rescue [--dry-run] [--yes] [--json]") }
        let (groups, processes) = toolGroups()
        let targets = groups.filter { !$0.rescueCopies.isEmpty }
        let identities = ToolProcesses.rescueIdentities(targets)
        let kb = targets.reduce(0) { $0 + $1.rescueKB }
        if app.args.has("dry-run") {
            struct Plan: Encodable { let dryRun = true; let action = "rescue"; let processes: Int; let memoryKB: Int; let groups: [ToolProcessGroup]; let steps: [String] }
            print(Export.json(Plan(processes: identities.count, memoryKB: kb, groups: targets,
                                   steps: ["recheck each PID identity", "SIGTERM", "wait 5 s", "SIGKILL what is still running", "re-measure swap"])))
            return
        }
        guard !identities.isEmpty else {
            actionOutput(tr("Nothing is left behind: no tool process has lost its starter or sat idle under a shared agent service for over an hour."))
            if app.args.has("json") { print(Export.json(ToolProcesses.Outcome())) }
            return
        }
        actionOutput(app.style.bold(tr("About to end %1$@ left-behind tool processes (about %2$@)", String(identities.count), Self.size(kb))))
        for g in ToolProcesses.summary(targets).prefix(20) {
            actionOutput("  \(g.name) ×\(g.rescueCopies)  \(Self.size(g.rescueKB))" + app.style.dim("  " + host(g)))
        }
        actionOutput(app.style.dim("  " + tr("AI agent sessions, apps and tools of a session in a terminal are not touched. A thread that still uses one of these tools loses it until it is restarted.")))
        actionOutput("  kill -TERM, then -KILL after 5 s if it does not stop")
        guard try confirm() else { return }
        let memory = Dictionary(processes.map { ($0.pid, $0.footprintKB) }, uniquingKeysWith: { a, _ in a })
        let outcome = ToolProcesses.end(identities, memoryKB: memory, subject: "rescue")
        actionOutput((outcome.stillRunning == 0 ? app.style.green("✓ ") : app.style.red("✗ ")) + outcome.summary)
        if app.args.has("json") { print(Export.json(outcome)) }
        if outcome.stillRunning > 0 { throw CLIError("not every process was ended", exitCode: 3) }
    }
}
