import AgentCore
import CleanKit
import Foundation

/// `thermo pulse why` and `thermo pulse end`: the 1–3 real culprits behind a slowdown, and ending
/// a stuck or runaway process (SIGTERM, then SIGKILL) with the effect measured afterwards.
extension PulseCommand {
    func why(_ rest: [String]) throws {
        guard rest.isEmpty else { throw CLIError("usage: thermo pulse why [--for SEC] [--json]") }
        let window = min(30, try app.args.double("for") ?? 3)
        let processes = SlowdownSampler().sample(window: window)
        let report = SlowdownDiagnosis.diagnose(processes, system: .read())
        if app.args.has("json") { print(Export.json(report)); return }
        let style = app.style
        print(style.bold(report.headline))
        if report.culprits.isEmpty { return }
        for (i, c) in report.culprits.enumerated() { printCulprit(c, index: i + 1) }
        if !report.also.isEmpty {
            print("")
            print(style.dim(tr("Also noticed:")))
            for c in report.also { print(style.dim("  · \(c.name) — \(MemoryFormat.string(kibibytes: c.memoryKB)) · \(c.evidence)")) }
        }
        print("")
        print(style.dim(tr("CPU is measured over %1$@ s; \"for N min\" comes from the process's own CPU time when Thermo has not watched it longer.", String(format: "%g", window))))
    }

    private func printCulprit(_ c: SlowdownCulprit, index: Int) {
        let style = app.style
        let effect = c.freesKB > 0 ? tr("frees ~%1$@", MemoryFormat.string(kibibytes: c.freesKB)) : ""
        let cpu = c.cpu >= 5 ? String(format: " · %.0f%% CPU", c.cpu) : ""
        print("")
        print(style.bold("\(index). \(c.name)") + style.dim("  " + [effect, cpu.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "· "))].filter { !$0.isEmpty }.joined(separator: " · ")))
        var origin: [String] = c.kind == .agentSessions || c.kind == .heavyApp ? [] : ["PID " + c.pids.prefix(1).map(String.init).joined()]
        if let l = c.launcher { origin.append(c.kind == .orphan ? l : tr("started by %1$@", l)) }
        if let p = c.project, !(c.launcher ?? "").contains(p) { origin.append(p) }
        if !origin.isEmpty { print(style.dim("   " + origin.joined(separator: " · "))) }
        print("   " + c.evidence)
        print("   " + style.yellow(c.guidance))
        for s in c.sessions?.prefix(10) ?? [] { print(style.dim("     " + s)) }
        if let cmd = c.command { print("   " + style.cyan("→ " + cmd)) }
    }

    func end(_ rest: [String]) throws {
        guard !rest.isEmpty, rest.allSatisfy({ Int32($0).map { $0 > 1 } ?? false }) else {
            throw CLIError("usage: thermo pulse end PID [--dry-run] [--yes] [--json]")
        }
        let pids = rest.compactMap { Int32($0) }
        let processes = SlowdownSampler().sample(window: 1)
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var targets: [(SlowdownProcess, ProcessIdentity?)] = []
        for pid in pids {
            guard let p = byPID[pid] else { throw CLIError("PID \(pid) is not running") }
            guard SlowdownFix.endable(p) else {
                throw CLIError(SlowdownFix.refusal(p).summary)
            }
            targets.append((p, ProcessTable.identity(pid)))
        }
        if app.args.has("dry-run") {
            struct Plan: Encodable { let dryRun = true; let action = "end"; let processes: [SlowdownProcess]; let steps: [String] }
            print(Export.json(Plan(processes: targets.map(\.0), steps: ["recheck PID identity", "SIGTERM", "wait 5 s", "SIGKILL if still running", "re-measure swap and load"])))
            return
        }
        for (p, _) in targets {
            actionOutput(app.style.bold(tr("About to end %1$@", SlowdownDiagnosis.friendlyName(p)))
                         + app.style.dim(String(format: "  PID %d · %.0f%% CPU · %@ · ", p.pid, p.cpu, Self.size(p.footprintKB)) + Self.duration(p.elapsed)))
            actionOutput(app.style.dim("  " + p.argv.joined(separator: " ").prefix(160)))
        }
        actionOutput("  kill -TERM, then -KILL after 5 s if it does not stop")
        guard try confirm() else { return }
        var results: [SlowdownFix.Result] = []
        for (p, identity) in targets {
            let r = SlowdownFix.end(p, identity: identity)
            results.append(r)
            actionOutput((r.outcome == .stopped || r.outcome == .killed ? app.style.green("✓ ") : app.style.red("✗ ")) + r.summary)
        }
        if let first = results.first, let swapBefore = first.swapBefore, let last = results.last, let swapAfter = last.swapAfter, let loadAfter = last.loadAfter {
            actionOutput(app.style.dim(tr("Swap used: %1$@ → %2$@. One-minute load: %3$@ → %4$@ (load averages take a minute or two to follow).",
                                          ByteFormat.string(Int64(swapBefore)), ByteFormat.string(Int64(swapAfter)),
                                          String(format: "%.1f", first.loadBefore), String(format: "%.1f", loadAfter))))
        }
        if app.args.has("json") { print(Export.json(results)) }
        if results.contains(where: { $0.outcome != .stopped && $0.outcome != .killed }) { throw CLIError("not every process was ended", exitCode: 3) }
    }
}
