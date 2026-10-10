import CleanKit
import Foundation
import ThermoKit

/// `thermo pulse`: one answer to "how is this Mac doing / why is it slow" — for people and agents.
struct PulseCommand {
    let app: App

    /// What `--json` prints: the pulse plus the sensor headline numbers.
    struct Report: Encodable {
        let verdict: String
        let summary: String
        let culprit: String?
        let load1: Double
        let load5: Double
        let cores: Int
        let thermal: String
        let memory: String
        let swapUsedMB: Int
        let programs: [MachinePulse.Hog]
        let temperatures: [String: Double]
        let fans: [Fan]
        let systemPowerW: Double?
        let batteryPercent: Double?

        struct Fan: Encodable { let name: String; let rpm: Double; let min: Double; let max: Double; let manual: Bool }
    }

    func run(_ rest: [String] = []) throws {
        if rest.first == "quit" { try quit(Array(rest.dropFirst())); return }
        let style = app.style
        let pulse = MachinePulse.sample()
        let sm = try? app.sampler()
        sm?.parts = [.temperatures, .fans, .power, .battery]
        let s = sm?.sample()

        if app.args.has("json") {
            var temps: [String: Double] = [:]
            if let v = s?.hottest { temps["hottest"] = v }
            if let v = s?.cpu { temps["cpu"] = v }
            if let v = s?.gpu { temps["gpu"] = v }
            print(Export.json(Report(
                verdict: pulse.verdict.rawValue, summary: pulse.verdictText, culprit: pulse.culpritText,
                load1: pulse.load1, load5: pulse.load5, cores: pulse.cores, thermal: pulse.thermal.rawValue,
                memory: pulse.memory.rawValue, swapUsedMB: pulse.swapUsedMB, programs: pulse.hogs, temperatures: temps,
                fans: (s?.fans ?? []).map { .init(name: $0.name, rpm: $0.rpm, min: $0.min, max: $0.max, manual: $0.manual) },
                systemPowerW: s?.systemPower, batteryPercent: s?.battery?.percent)))
            return
        }

        let mark = pulse.verdict == .ok ? style.green("✓") : pulse.verdict == .busy ? style.yellow("!") : style.red("!")
        var lines = [mark + " " + style.bold(pulse.verdictText)]
        if let c = pulse.culpritText { lines.append("  " + c) }
        lines.append(style.dim(String(format: "  load %.1f / %.1f (1 / 5 min) on %d cores · memory %@ · swap %d MB · thermal %@",
                                      pulse.load1, pulse.load5, pulse.cores, pulse.memory.rawValue, pulse.swapUsedMB,
                                      pulse.thermal.rawValue)))
        if !pulse.hogs.isEmpty {
            lines.append("")
            lines.append(style.bold("Busiest programs"))
            for h in pulse.hogs {
                let cpu = String(format: "%5.0f%%", h.cpu)
                lines.append("  " + (h.cpu >= 100 ? style.red(cpu) : h.cpu >= 50 ? style.yellow(cpu) : cpu)
                             + "  " + pad(h.memoryKB >= 1_048_576 ? String(format: "%.1f GB", Double(h.memoryKB) / 1_048_576) : "\(h.memoryKB / 1024) MB", 8, right: true)
                             + "  " + h.name + style.dim(h.pids.count > 1 ? "  (\(h.pids.count) processes)" : "  pid \(h.pids[0])")
                             + style.dim([h.project, h.owner.map { "started by " + $0 }].compactMap { $0 }.map { "  · " + $0 }.joined()))
            }
        }
        if let s {
            lines.append("")
            var sensors: [String] = []
            if let t = s.hottest { sensors.append("hottest " + style.temp(t, width: 0)) }
            if let t = s.cpu { sensors.append("CPU " + style.temp(t, width: 0)) }
            if let t = s.gpu { sensors.append("GPU " + style.temp(t, width: 0)) }
            if let w = s.systemPower { sensors.append(String(format: "%.1f W", w)) }
            lines.append("  " + sensors.joined(separator: style.dim(" · ")))
            for f in s.fans {
                lines.append("  " + f.name + "  \(Int(f.rpm)) rpm" + style.dim("  [\(Int(f.min))–\(Int(f.max))] " + (f.manual ? "manual" : "auto")))
            }
        }
        out(lines)
    }

    // MARK: quit

    /// `thermo pulse quit NAME|PID`: the card's Quit button. Apps are asked to quit like ⌘Q;
    /// other processes get SIGTERM. System processes, AI agent sessions and Thermo are refused.
    func quit(_ targets: [String]) throws {
        guard let target = targets.first else { throw CLIError("usage: thermo pulse quit NAME|PID [--yes]") }
        let style = app.style
        let pulse = MachinePulse.sample()
        // Look beyond the top few: anything this user runs can be named.
        let all = MachinePulse.group(ProcessTable.current(.init(cpu: false)).entries, byMemory: true, limit: nil)
        let lower = target.lowercased()
        let matches: [MachinePulse.Hog]
        if let pid = Int32(target) {
            matches = all.filter { $0.pids.contains(pid) }
        } else {
            let exact = all.filter { $0.name.lowercased() == lower }
            matches = exact.isEmpty ? all.filter { $0.name.lowercased().contains(lower) } : exact
        }
        guard !matches.isEmpty else { throw CLIError("no running program matches '\(target)'; see thermo pulse") }
        guard matches.count == 1 else {
            throw CLIError("'\(target)' matches several programs: " + matches.map { "\($0.name) (pid \($0.pids[0]))" }.joined(separator: ", "))
        }
        let h = matches[0]
        guard h.quittable else {
            throw CLIError("\(h.name) is not offered for quitting (system process, AI agent session or Thermo itself)")
        }
        _ = pulse
        let plan = h.app.map { "quit \($0)  (like ⌘Q; it may ask to save)" }
            ?? "kill -TERM " + h.pids.map(String.init).joined(separator: " ")
        print(style.bold("About to stop \(h.name)") + style.dim(String(format: "  %.0f%% CPU · %d MB", h.cpu, h.memoryKB / 1024)))
        print("  " + plan)
        if !app.args.has("yes") {
            guard isatty(STDIN_FILENO) != 0 else { throw CLIError("not a terminal; add --yes to confirm") }
            print("Proceed? [y/N] ", terminator: "")
            fflush(stdout)
            guard let a = readLine(), ["y", "yes"].contains(a.lowercased()) else { print("cancelled"); return }
        }
        if let path = h.app {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application \"\(path.replacingOccurrences(of: "\"", with: "\\\""))\" to quit"]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw CLIError("\(h.name) did not quit (it may have asked to save, or refused)") }
        } else {
            for pid in h.pids where pid != getpid() { kill(pid, SIGTERM) }
        }
        print(style.green("✓") + " asked \(h.name) to stop")
    }
}

