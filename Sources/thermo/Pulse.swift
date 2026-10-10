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
        if rest.first == "history" { try history(); return }
        if rest.first == "chrome" { try chrome(Array(rest.dropFirst())); return }
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
        lines.append(style.dim("  " + tr("load %1$@ / %2$@ (1 / 5 min) on %3$@ cores · memory %4$@ · swap %5$@ · temperature %6$@",
                                         String(format: "%.1f", pulse.load1), String(format: "%.1f", pulse.load5), String(pulse.cores),
                                         MachinePulse.memoryName(pulse.memory), Self.size(pulse.swapUsedMB * 1024),
                                         MachinePulse.thermalName(pulse.thermal))))
        if !pulse.hogs.isEmpty {
            lines.append("")
            lines.append(style.bold(tr("Busiest programs")))
            for h in pulse.hogs {
                let cpu = String(format: "%5.0f%%", h.cpu)
                lines.append("  " + (h.cpu >= 100 ? style.red(cpu) : h.cpu >= 50 ? style.yellow(cpu) : cpu)
                             + "  " + pad(Self.size(h.memoryKB), 8, right: true)
                             + "  " + h.name + style.dim(h.pids.count > 1 ? "  " + tr("(%1$@ processes)", String(h.pids.count)) : "  pid \(h.pids[0])")
                             + style.dim([h.project, h.owner.map { tr("started by %1$@", $0) },
                                          h.uptime.map { tr("running %1$@", Self.duration($0)) }].compactMap { $0 }.map { "  · " + $0 }.joined()))
                // Big apps, split: the GPU process and the heaviest pages, each with how long it has run.
                for p in h.parts ?? [] {
                    lines.append(style.dim("            " + pad(Self.size(p.memoryKB), 8, right: true) + "  " + MachinePulse.roleName(p.role)
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
            if let t = s.hottest { sensors.append(tr("hottest") + " " + style.temp(t, width: 0)) }
            if let t = s.cpu { sensors.append("CPU " + style.temp(t, width: 0)) }
            if let t = s.gpu { sensors.append("GPU " + style.temp(t, width: 0)) }
            if let w = s.systemPower { sensors.append(String(format: "%.1f W", w)) }
            lines.append("  " + sensors.joined(separator: style.dim(" · ")))
            for f in s.fans {
                lines.append("  " + f.name + "  \(Int(f.rpm)) rpm" + style.dim("  [\(Int(f.min))–\(Int(f.max))] " + (f.manual ? tr("manual") : tr("auto"))))
            }
        }
        out(lines)
    }

    // MARK: quit

    /// `thermo pulse quit NAME|PID`: the card's Quit button. Apps are asked to quit like ⌘Q;
    /// other processes get SIGTERM. System processes, AI agent sessions and Thermo are refused.
    /// `thermo pulse history [--since 1h|6h|24h]`: who slowed the Mac down, from what Thermo.app
    /// recorded in the background.
    func history() throws {
        let style = app.style
        let spec = app.args.options["since"] ?? "6h"
        guard let hours = Self.hours(spec) else { throw CLIError("--since expects 30m, 1h, 6h or 24h; got '\(spec)'") }
        let since = Date().addingTimeInterval(-hours * 3600)
        let records = PulseHistory().records(since: since)
        let blame = PulseHistory.blame(records)
        let struggling = records.filter { $0.load1 >= Double(max(1, $0.cores)) || $0.memory != .normal || $0.thermal == .serious || $0.thermal == .critical }
        let peakLoad = records.map(\.load1).max() ?? 0
        let peakSwap = records.map(\.swapUsedMB).max() ?? 0
        if app.args.has("json") {
            struct Out: Encodable {
                let since: Date; let records: Int; let strugglingRecords: Int; let peakLoad: Double; let peakSwapMB: Int
                let blame: [PulseHistory.Share]
            }
            print(Export.json(Out(since: since, records: records.count, strugglingRecords: struggling.count,
                                  peakLoad: peakLoad, peakSwapMB: peakSwap, blame: blame)))
            return
        }
        guard !records.isEmpty else {
            print(style.dim(tr("No history yet. Thermo.app records it in the background once a minute; open Thermo once and leave it running.")))
            return
        }
        var lines = [style.bold(tr("Last %1$@", spec)) + style.dim("  " + tr("%1$@ samples · peak load %2$@ · peak swap %3$@",
                                                                       String(records.count), String(Int(peakLoad.rounded())), Self.size(peakSwap * 1024)))]
        if struggling.isEmpty {
            lines.append("  " + style.green("✓") + " " + tr("nothing slowed the Mac down"))
        } else {
            lines.append("  " + tr("the Mac was struggling in %1$@ of %2$@ samples", String(struggling.count), String(records.count)))
            lines.append("")
            lines.append(style.bold(tr("Who was behind it")) + style.dim("  " + tr("(minutes at the top while it struggled)")))
            for s in blame.prefix(8) {
                lines.append("  " + pad(tr("%1$@ min", String(s.minutes)), 8, right: true) + "  " + pad(s.name, 24)
                             + style.dim(tr("peak %1$@ CPU · %2$@", String(format: "%.0f%%", s.peakCPU), Self.size(s.peakMemoryKB))
                                         + ([s.project, s.owner.map { tr("started by %1$@", $0) }].compactMap { $0 }.map { "  · " + $0 }.joined())))
            }
        }
        out(lines)
    }

    static func hours(_ s: String) -> Double? {
        let t = s.lowercased()
        if t.hasSuffix("h"), let v = Double(t.dropLast()), v > 0 { return min(v, 24) }
        if t.hasSuffix("m"), let v = Double(t.dropLast()), v > 0 { return v / 60 }
        return Double(t).map { min($0, 24) }
    }

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
        let windows = BrowserSession.windows(for: h.name)
        print("  quit \(path)  (like ⌘Q; it may ask to save)")
        print("  open \(path)")
        if windows == .thermoReopensTabs { print("  reopen its tabs  (saved to \(BrowserSession.backupURL().path))") }
        print("  " + style.yellow(MachinePulse.restartNote(windows)))
        guard try confirm() else { return }
        var saved: BrowserSession.Saved?
        if windows == .thermoReopensTabs {
            // Without the tab list, quitting would lose them: don't.
            guard let s = BrowserSession.save(app: h.name) else {
                throw CLIError("could not list \(h.name)'s tabs (allow Automation in System Settings → Privacy & Security); nothing was restarted")
            }
            saved = s
            print(style.dim("  saved \(s.tabCount) tabs in \(s.windows.count) windows"))
        }
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
        if let saved {
            guard BrowserSession.reopen(saved) else {
                throw CLIError("\(h.name) restarted but its tabs could not be reopened; they are listed in \(BrowserSession.backupURL().path)")
            }
            print(style.green("✓") + " restarted \(h.name) and reopened \(saved.tabCount) tabs")
            return
        }
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
        MemoryFormat.string(kibibytes: kb)
    }

    static func duration(_ s: TimeInterval) -> String {
        let d = Int(s / 86400), h = Int(s.truncatingRemainder(dividingBy: 86400) / 3600), m = Int(s / 60)
        return d > 0 ? tr("%1$@d %2$@h", String(d), String(h)) : s >= 3600 ? tr("%1$@h", String(Int(s / 3600))) : tr("%1$@m", String(m))
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
        print(style.bold("About to stop \(h.name)") + style.dim(String(format: "  %.0f%% CPU · %@", h.cpu, Self.size(h.memoryKB))))
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

