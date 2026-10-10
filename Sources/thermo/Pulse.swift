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
        let swapTotalMB: Int
        /// "Swap files take N GB of disk space …" when they are big.
        let swapNote: String?
        /// Every program's advice in one place (e.g. "restart Chrome, frees about 19 GB").
        let advice: [String]
        let programs: [MachinePulse.Hog]
        let temperatures: [String: Double]
        let fans: [Fan]
        let systemPowerW: Double?
        let batteryPercent: Double?

        struct Fan: Encodable { let name: String; let rpm: Double; let min: Double; let max: Double; let manual: Bool }
    }

    func run(_ rest: [String] = []) throws {
        if rest.first == "quit" { try quit(Array(rest.dropFirst())); return }
        if rest.first == "restart" { try restart(Array(rest.dropFirst())); return }
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
                memory: pulse.memory.rawValue, swapUsedMB: pulse.swapUsedMB, swapTotalMB: pulse.swapTotalMB,
                swapNote: pulse.swapDiskText, advice: pulse.hogs.compactMap { $0.advice?.text },
                programs: pulse.hogs, temperatures: temps,
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
                             + style.dim([h.project, h.owner.map { "started by " + $0 },
                                          h.uptime.map { "running " + Self.duration($0) }].compactMap { $0 }.map { "  · " + $0 }.joined()))
                // Big apps, split: the GPU process and the heaviest pages, each with how long it has run.
                for p in h.parts ?? [] {
                    lines.append(style.dim("            " + pad(Self.size(p.memoryKB), 8, right: true) + "  " + p.role
                                           + (p.uptime.map { "  · " + Self.duration($0) } ?? "") + "  · pid \(p.pid)"))
                }
                if let a = h.advice {
                    lines.append("            " + style.yellow("→ " + a.text) + style.dim("  thermo pulse restart \"\(h.name)\""))
                }
            }
        }
        if let note = pulse.swapDiskText { lines.append(""); lines.append("  " + style.dim(note)) }
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
    /// The one running program `target` names (a pid, an exact name, or a unique part of one).
    func pick(_ target: String) throws -> MachinePulse.Hog {
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
        return matches[0]
    }

    func confirm() throws -> Bool {
        if app.args.has("yes") { return true }
        guard isatty(STDIN_FILENO) != 0 else { throw CLIError("not a terminal; add --yes to confirm") }
        print("Proceed? [y/N] ", terminator: "")
        fflush(stdout)
        guard let a = readLine(), ["y", "yes"].contains(a.lowercased()) else { print("cancelled"); return false }
        return true
    }

    /// `thermo pulse restart NAME`: quit an app like ⌘Q, wait until it has gone, open it again.
    /// The app restores its own windows and tabs; what it had piled up in memory is freed.
    func restart(_ targets: [String]) throws {
        guard let target = targets.first else { throw CLIError("usage: thermo pulse restart NAME|PID [--yes]") }
        let style = app.style
        let h = try pick(target)
        guard h.quittable, let path = h.app else {
            throw CLIError("\(h.name) can't be restarted from here (not an app, a system process, an AI agent session or Thermo)")
        }
        print(style.bold("About to restart \(h.name)") + style.dim("  \(Self.size(h.memoryKB))" + (h.uptime.map { " · running " + Self.duration($0) } ?? "")))
        print("  quit \(path)  (like ⌘Q; it may ask to save)")
        print("  open \(path)  (it reopens its windows)")
        guard try confirm() else { return }
        try quitApp(path, name: h.name)
        // Wait for every process of it to go; apps can take a while to save and close.
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, h.pids.contains(where: { kill($0, 0) == 0 }) { usleep(250_000) }
        guard !h.pids.contains(where: { kill($0, 0) == 0 }) else {
            throw CLIError("\(h.name) has not quit after a minute (it may be asking to save); nothing was reopened")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CLIError("\(h.name) quit but could not be reopened; open it yourself") }
        print(style.green("✓") + " restarted \(h.name)")
    }

    func quitApp(_ path: String, name: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"\(path.replacingOccurrences(of: "\"", with: "\\\""))\" to quit"]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CLIError("\(name) did not quit (it may have asked to save, or refused)") }
    }

    static func size(_ kb: Int) -> String {
        kb >= 1_048_576 ? String(format: "%.1f GB", Double(kb) / 1_048_576) : "\(kb / 1024) MB"
    }

    static func duration(_ s: TimeInterval) -> String {
        s >= 86400 ? String(format: "%.0fd %.0fh", (s / 86400).rounded(.down), (s.truncatingRemainder(dividingBy: 86400) / 3600).rounded(.down))
            : s >= 3600 ? String(format: "%.0fh", (s / 3600).rounded(.down)) : String(format: "%.0fm", s / 60)
    }

    func quit(_ targets: [String]) throws {
        guard let target = targets.first else { throw CLIError("usage: thermo pulse quit NAME|PID [--yes]") }
        let style = app.style
        let h = try pick(target)
        guard h.quittable else {
            throw CLIError("\(h.name) is not offered for quitting (system process, AI agent session or Thermo itself)")
        }
        let plan = h.app.map { "quit \($0)  (like ⌘Q; it may ask to save)" }
            ?? "kill -TERM " + h.pids.map(String.init).joined(separator: " ")
        print(style.bold("About to stop \(h.name)") + style.dim(String(format: "  %.0f%% CPU · %d MB", h.cpu, h.memoryKB / 1024)))
        print("  " + plan)
        guard try confirm() else { return }
        if let path = h.app {
            try quitApp(path, name: h.name)
        } else {
            for pid in h.pids where pid != getpid() { kill(pid, SIGTERM) }
        }
        print(style.green("✓") + " asked \(h.name) to stop")
    }
}

