import CleanKit
import AgentDoctor
import Foundation
import ThermoKit

/// `thermo pulse`: one answer to "how is this Mac doing / why is it slow" — for people and agents.
struct PulseCommand {
    let app: App

    /// What `--json` prints: the pulse plus the sensor headline numbers.
    struct Report: Encodable {
        let sampled: Date
        /// What each number means (units, memory metric); see MachinePulse.units.
        let units: [String: String]
        let selection: String
        let verdict: String
        let summary: String
        let culprit: String?
        let nextStep: MachinePulse.NextStep?
        let load1: Double
        let load5: Double
        let cores: Int
        let thermal: String
        let memory: String
        let swapUsedMB: Int
        let swapTotalMB: Int
        /// "Swap files take N GB of disk space …" when they are big.
        let swapNote: String?
        /// Free space on the startup disk, and a warning once it runs low.
        let diskFreeBytes: Int64?
        let diskNote: String?
        /// Every program's advice in one place (e.g. "restart Chrome, frees about 19 GB").
        let advice: [String]
        let programs: [MachinePulse.Hog]
        let temperatures: [String: Double]
        let fans: [Fan]
        let systemPowerW: Double?
        let batteryPercent: Double?

        struct Fan: Encodable {
            let name: String; let rpm: Double?; let min: Double?; let max: Double?; let manual: Bool?
            let controlMode: String
            init(_ reading: FanReading) {
                name = reading.name; rpm = reading.rpm; min = reading.min; max = reading.max
                manual = reading.manual; controlMode = reading.controlMode
            }
        }
    }

    func run(_ rest: [String] = []) throws {
        guard rest.isEmpty || ["explain","quit","restart","history","inspect","chrome"].contains(rest[0]) else { throw CLIError("Unknown pulse operation. Run thermo pulse --help.") }
        if rest.first == "explain" {
            guard rest.count == 2, let pid = Int32(rest[1]), pid > 0 else { throw CLIError("usage: thermo pulse explain PID [--json]") }
            let report = try ProcessExplanation.capture(pid)
            if app.args.has("json") { print(Export.diagnosticJSON(report)); return }
            var lines = [tr("Why is this running?"), "PID \(report.pid)", tr("Observed at %1$@", report.sampled.ISO8601Format()), tr("Observed parent chain")]
            if let application = report.application { lines.append(tr(report.attribution == .executableLocation ? "Executable located inside: %1$@" : "Observed ancestor application: %1$@", application)) }
            else { lines.append(tr("No application attribution was established")) }
            for node in report.chain {
                lines.append("\(node.name) · PID \(node.pid) → \(node.parentPID) · " + node.executable)
                if let cwd = node.workingDirectory { lines.append(tr("Working directory: %1$@", cwd)) }
                if !node.args.isEmpty { lines.append(node.args.map { String(reflecting: $0) }.joined(separator: " ")) }
            }
            lines += report.issues.map { tr($0) }
            lines.append(tr("Observed descendant processes"))
            if let descendants=report.descendants {
                lines += descendants.children.map { String(repeating:"  ",count:max(0,$0.depth-1)) + "\($0.name) · PID \($0.pid) → \($0.parentPID) · UID \($0.uid) · " + $0.executable }
                if descendants.state == .noneObserved { lines.append(tr("No descendants were observed in this process reading.")) }
                if descendants.state == .unavailable { lines.append(tr("Descendant relationships are unavailable.")) }
                if !descendants.queryComplete { lines.append(tr("The descendant reading is incomplete; some relationships could not be verified.")) }
                if descendants.limited { lines.append(tr("The descendant reading reached an inspection limit.")) }
            } else { lines.append(tr("Descendant relationships are unavailable.")) }
            lines.append(tr("Processes can start, exit or change parents after this reading. This tree does not prove the original launcher."))
            lines.append(tr("Git context near the process working directory"))
            if let git=report.gitContext,git.state == .observed {
                if let root=git.root { lines.append(tr("Repository: %1$@",root)) }
                if let branch=git.branch { lines.append(tr("Branch: %1$@",branch)) }
                if git.detached == true { lines.append(tr("Detached HEAD")) }
                if let commit=git.commit { lines.append(tr("HEAD: %1$@",commit)) }
                if !git.queryComplete { lines.append(tr("The branch was observed, but its commit could not be established.")) }
            } else { lines.append(tr(report.gitContext?.state == .noneObserved ? "No Git marker was observed in the working directory or its inspected parents." : "Git context is unavailable or changed during inspection.")) }
            lines.append(tr("Working directory metadata does not prove which project the process is using. Git status, remotes and repository scripts are not inspected."))
            lines.append(tr("Observed cwd and vnode descriptor paths")); lines += report.observedPaths ?? [tr("Path inspection is unavailable for this process")]
            lines.append(tr("Observed TCP listeners"))
            if let listeners = report.listeners {
                lines += listeners.endpoints.map { $0.label + " · " + $0.family + " · " + $0.addressKind.rawValue }
                if listeners.state == .noneObserved { lines.append(tr("No TCP listeners were observed; this does not prove none exist.")) }
                if listeners.state == .unavailable { lines.append(tr("TCP listener inspection is unavailable")) }
                if !listeners.queryComplete { lines.append(tr("TCP listener reading is incomplete")) }
                if listeners.limited { lines.append(tr("TCP listener reading reached a limit")) }
            } else { lines.append(tr("TCP listener inspection is unavailable")) }
            lines.append(tr("A listening address does not prove internet reachability."))
            lines.append(tr("A current parent chain does not prove the original launcher or a publisher's identity."))
            lines.append(tr("Observed process power assertions"))
            if let power = report.sleepAssertions {
                lines += power.assertions.map { $0.type + " · " + tr($0.active == true ? "Active request" : $0.active == false ? "Inactive request" : "Unknown assertion level") + " · " + $0.request.rawValue + ($0.name.map { " · " + $0 } ?? "") }
                if power.state == .noneObserved { lines.append(tr("No process assertions were observed; other mechanisms may still prevent sleep.")) }
                if power.state == .unavailable { lines.append(tr("Power assertion inspection is unavailable")) }
                if !power.queryComplete { lines.append(tr("Power assertion reading is incomplete")) }
                if power.limited { lines.append(tr("Power assertion reading reached a limit")) }
            } else { lines.append(tr("Power assertion inspection is unavailable")) }
            lines.append(tr("Power requests do not guarantee prevention of lid-close, low-battery or policy-driven sleep."))
            lines.append(tr("Observed launchd service registrations"))
            if let services = report.launchServices {
                lines += services.registrations.map { $0.domain + "/" + $0.label + " · PID " + String($0.pid) + ($0.serviceState.map { " · " + $0 } ?? "") }
                if !services.queriedDomains.isEmpty { lines.append(tr("Launchd query scope: %1$@", services.queriedDomains.joined(separator: ", "))) }
                if services.state == .noneObserved { lines.append(tr("No direct registration was observed in the queried launchd domains.")) }
                if services.state == .unavailable { lines.append(tr("Launchd registration inspection is unavailable")) }
                if !services.queryComplete { lines.append(tr("Launchd registration reading is incomplete")) }
            } else { lines.append(tr("Launchd registration inspection is unavailable")) }
            lines.append(tr("A registration does not prove the original launcher. Service attribution uses only the exact PID."))
            lines.append(tr("Memory mappings were not inspected."))
            lines.append(tr("Known credential patterns are masked. Custom arguments and assertion names may contain personal data."))
            out(lines); return
        }
        if rest.first == "quit" { try quit(Array(rest.dropFirst())); return }
        if rest.first == "restart" { try restart(Array(rest.dropFirst())); return }
        if rest.first == "history" { try history(); return }
        if rest.first == "inspect" { try inspect(Array(rest.dropFirst())); return }
        if rest.first == "chrome" { try chrome(Array(rest.dropFirst())); return }
        let style = app.style
        let pulse = MachinePulse.sample()
        let sm = try? app.sampler()
        sm?.parts = [.temperatures, .fans, .power, .battery]
        let s = sm?.sample()

        if app.args.has("json") || app.args.has("csv") {
            var temps: [String: Double] = [:]
            if let v = s?.maximumKnownTemperature { temps["hottest"] = v }
            if let v = s?.cpu { temps["cpu"] = v }
            if let v = s?.gpu { temps["gpu"] = v }
            let report = Report(
                sampled: pulse.sampled, units: MachinePulse.units, selection: MachinePulse.selection,
                verdict: pulse.verdict.rawValue, summary: pulse.verdictText, culprit: pulse.culpritText, nextStep: pulse.nextStep,
                load1: pulse.load1, load5: pulse.load5, cores: pulse.cores, thermal: pulse.thermal.rawValue,
                memory: pulse.memory.rawValue, swapUsedMB: pulse.swapUsedMB, swapTotalMB: pulse.swapTotalMB,
                swapNote: pulse.swapDiskText, diskFreeBytes: pulse.diskFreeBytes, diskNote: pulse.diskText, advice: pulse.hogs.compactMap { $0.advice?.text },
                programs: pulse.hogs, temperatures: temps,
                fans: (s?.fans ?? []).map { .init($0) },
                systemPowerW: s?.systemPower, batteryPercent: s?.battery?.percent)
            print(app.args.has("json") ? Export.diagnosticJSON(report) : Export.pulseCSV(report))
            return
        }

        let mark = pulse.verdict == .ok ? style.green("✓") : pulse.verdict == .busy ? style.yellow("!") : style.red("!")
        var lines = [mark + " " + style.bold(pulse.verdictText)]
        if let c = pulse.culpritText { lines.append("  " + c) }
        if let next = pulse.nextStep {
            lines.append("  " + next.text)
            if next.kind == "inspectBrowser", let program = next.program {
                lines.append(style.dim("  thermo pulse chrome --app " + ("'" + program.replacingOccurrences(of: "'", with: "'\"'\"'") + "'") + " --watch 30"))
            }
        }
        lines.append(style.dim("  " + tr("load %1$@ / %2$@ (1 / 5 min) on %3$@ cores · memory %4$@ · swap %5$@ · thermal pressure %6$@",
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
                             + style.dim([h.project, h.owner.map { tr("observed ancestor: %1$@", $0) },
                                          h.uptime.map { tr("running %1$@", Self.duration($0)) }].compactMap { $0 }.map { "  · " + $0 }.joined()))
                // Big apps, split: the GPU process and the heaviest pages, each with how long it has run.
                let parts = h.parts ?? []
                for p in parts.prefix(Self.partsShown) {
                    lines.append(style.dim("            " + pad(Self.size(p.memoryKB), 8, right: true) + "  " + MachinePulse.roleName(p.role)
                                           + (p.uptime.map { "  · " + Self.duration($0) } ?? "") + "  · pid \(p.pid)"))
                }
                if parts.count > Self.partsShown {
                    lines.append(style.dim("            " + tr("… and %1$@ more processes (%2$@ in all)", String(parts.count - Self.partsShown), Self.size(h.memoryKB))))
                }
                if h.owner == nil, let owners = h.owners {
                    lines.append(style.dim("            " + tr("observed ancestor: %1$@", owners.joined(separator: ", "))))
                }
                if let e = h.elsewhere {
                    lines.append(style.dim("            " + tr("also %1$@ processes in %2$@ other folders (%3$@)", String(e.processes), String(e.projects.count), Self.size(e.memoryKB))
                                           + "  thermo pulse inspect \"\(h.name)\""))
                }
                if let a = h.advice {
                    lines.append("            " + style.yellow("→ " + a.text) + style.dim("  thermo pulse restart \"\(h.name)\""))
                }
            }
        }
        if let note = pulse.diskText { lines.append(""); lines.append("  " + style.yellow(note)) }
        if let note = pulse.swapDiskText { lines.append(""); lines.append("  " + style.dim(note)) }
        if let s {
            lines.append("")
            var sensors: [String] = []
            if let t = s.maximumKnownTemperature { sensors.append(tr("hottest") + " " + style.temp(t, width: 0)) }
            if let t = s.cpu { sensors.append("CPU " + style.temp(t, width: 0)) }
            if let t = s.gpu { sensors.append("GPU " + style.temp(t, width: 0)) }
            if let w = s.systemPower { sensors.append(String(format: "%.1f W", w)) }
            lines.append("  " + sensors.joined(separator: style.dim(" · ")))
            for f in s.fans {
                lines.append("  " + f.name + "  \(Renderer.fanNumber(f.rpm)) rpm" + style.dim("  [\(Renderer.fanNumber(f.min))–\(Renderer.fanNumber(f.max))] " + (tr(f.controlMode))))
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
        let struggling = records.filter { $0.load1 >= Double(max(1, $0.cores)) || $0.memory.isHigh || $0.thermal == .serious || $0.thermal == .critical }
        let peakLoad = records.map(\.load1).max() ?? 0
        let peakSwap = records.map(\.swapUsedMB).max() ?? 0
        if app.args.has("json") || app.args.has("csv") {
            struct Out: Encodable {
                let since: Date; let records: Int; let strugglingRecords: Int; let peakLoad: Double; let peakSwapMB: Int
                let units: [String: String]
                let blame: [PulseHistory.Share]
            }
            let units = ["peakMemoryKB": "KiB, the row's largest reading while it was at the top; memoryMetric says how it was measured (footprint unless said; older records have none)",
                         "peakCPU": MachinePulse.units["cpu"] ?? "", "peakSwapMB": "MiB of swap in use, whole machine",
                         "minutes": "minutes among the top three while the Mac was struggling (load ≥ cores, memory pressure or throttling)",
                         "peakProcesses": "most processes the row had at those moments; recorded since 1.1.26"]
            let report = Out(since: since, records: records.count, strugglingRecords: struggling.count,
                             peakLoad: peakLoad, peakSwapMB: peakSwap, units: units, blame: blame)
            print(app.args.has("json") ? Export.diagnosticJSON(report) : Export.pulseCSV(report))
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
                                         + ([s.peakProcesses.map { tr("(%1$@ processes)", String($0)) }, s.project, s.owner.map { tr("recorded association: %1$@", $0) }].compactMap { $0 }.map { "  · " + $0 }.joined())))
            }
        }
        out(lines)
    }

    static let partsShown = 5

    /// `thermo pulse inspect NAME|PID`: every copy of one program, in every folder, with each
    /// process's memory, CPU, start, parent and owner: what to check before calling copies leftovers.
    func inspect(_ targets: [String]) throws {
        guard let target = targets.first else { throw CLIError("usage: thermo pulse inspect NAME|PID [--json]") }
        let style = app.style
        // Everyone's processes for the parent chain (it passes root-owned `login`); only this user's are listed.
        let everyone = ProcessTable.current(.init(uid: nil))
        let byPid = Dictionary(everyone.entries.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let sampler=PulseSampler()
        func owner(_ p: AgentProcess) -> String? { sampler.owner(of:p,in:byPid) }
        let uid = getuid()
        let all = MachinePulse.group(everyone.entries.filter { $0.uid == uid }, byMemory: true, limit: nil, owner: owner)
        let lower = target.lowercased()
        var rows: [MachinePulse.Hog]
        if let pid = Int32(target) {
            // A pid names its program; show every copy of that program.
            guard let h = all.first(where: { $0.pids.contains(pid) }) else { throw CLIError("no process \(pid) of yours is running") }
            rows = all.filter { $0.name == h.name && ($0.app == nil) == (h.app == nil) }
        } else {
            rows = all.filter { $0.name.lowercased() == lower }
            if rows.isEmpty { rows = all.filter { $0.name.lowercased().contains(lower) } }
        }
        guard !rows.isEmpty else { throw CLIError("no running program matches '\(target)'; see thermo pulse or thermo memory") }
        rows.sort { $0.memoryKB > $1.memoryKB }
        let names = Set(rows.map(\.name))
        let parts = rows.flatMap { $0.parts ?? [] }
        // PPID 1 can mean direct launchd startup or adoption; it cannot prove a parent's exit.
        let orphaned = rows.filter { $0.app == nil }.flatMap { $0.parts ?? [] }.filter { $0.ppid == 1 }.count
        let metrics = Set(rows.compactMap(\.memoryMetric))
        let metric: MachinePulse.MemoryMetric? = metrics.count == 1 ? metrics.first : metrics.isEmpty ? nil : .mixed
        let resident: Int? = parts.allSatisfy { $0.residentKB != nil } ? parts.reduce(0) { $0 + ($1.residentKB ?? 0) } : nil
        if app.args.has("json") {
            struct Out: Encodable {
                let sampled: Date; let units: [String: String]; let query: String; let programs: [String]
                let processes: Int; let rows: Int; let cpu: Double; let memoryKB: Int; let memoryMetric: MachinePulse.MemoryMetric?
                let residentKB: Int?; let orphaned: Int; let orphanedNote: String; let ownerMeaning: String
                let inventoryComplete: Bool; let programsDetail: [MachinePulse.Hog]
            }
            var units = MachinePulse.units
            units["cpu"] = "percent of one core, decayed average like ps -o pcpu"
            print(Export.diagnosticJSON(Out(sampled: Date(), units: units, query: target, programs: names.sorted(), processes: parts.count,
                                            rows: rows.count, cpu: rows.reduce(0) { $0 + $1.cpu }, memoryKB: rows.reduce(0) { $0 + $1.memoryKB },
                                            memoryMetric: metric, residentKB: resident, orphaned: orphaned,
                                            orphanedNote: "legacy field orphaned counts command-line processes with current parent PID 1 (launchd); this does not prove a parent exited or the process is leftover",
                                            ownerMeaning: "identity-checked agent, terminal or editor observed in the current ancestor chain; not proof of the original launcher",
                                            inventoryComplete: everyone.inventoryComplete,
                                            programsDetail: rows)))
            return
        }
        let metricName = metric == .footprint ? tr("footprint") : metric == .residentEstimate ? tr("resident") : tr("mixed measures")
        var lines = [style.bold(names.sorted().joined(separator: ", "))
                     + "  " + tr("%1$@ processes in %2$@ rows", String(parts.count), String(rows.count))
                     + style.dim("  · " + Self.size(rows.reduce(0) { $0 + $1.memoryKB }) + " " + metricName
                                 + (resident.map { " · " + Self.size($0) + " " + tr("resident (RSS)") } ?? "")
                                 + String(format: " · %.0f%% CPU", rows.reduce(0) { $0 + $1.cpu }))]
        if !everyone.inventoryComplete {
            lines.append(style.yellow(tr("The process inventory is incomplete; totals cover observed processes only.")))
        }
        if orphaned > 0 {
            lines.append("  " + style.yellow(tr("%1$@ processes currently have launchd as parent; this does not prove a parent exited.", String(orphaned))))
        }
        for h in rows {
            lines.append("")
            lines.append("  " + style.bold(h.app ?? h.project ?? h.name) + style.dim("  " + tr("(%1$@ processes)", String(h.pids.count)) + " · " + Self.size(h.memoryKB)
                                                                         + ((h.owner.map { [$0] } ?? h.owners).map { " · " + tr("observed ancestor: %1$@", $0.joined(separator: ", ")) } ?? "")))
            for p in h.parts ?? [] {
                let parent = p.ppid.map { $0 == 1 && h.app == nil ? style.yellow(tr("parent: launchd")) : "ppid \($0)" } ?? ""
                lines.append("    " + pad("pid \(p.pid)", 11) + pad(Self.size(p.memoryKB), 9, right: true)
                             + style.dim(pad(p.residentKB.map { "RSS " + Self.size($0) } ?? "", 14, right: true)
                                         + pad(String(format: "%.0f%%", p.cpu), 6, right: true)
                                         + "  " + (p.uptime.map(Self.duration) ?? "—"))
                             + "  " + parent
                             + style.dim(h.owner == nil ? (p.owner.map { "  · " + $0 } ?? "") : ""))
            }
        }
        lines.append("")
        lines.append(style.dim(tr("Memory is %1$@; RSS counts shared pages in every process and is not comparable with it. Many copies or long uptimes alone do not prove a leak.", metricName)))
        out(lines)
    }

    static func hours(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let number = t.hasSuffix("h") || t.hasSuffix("m") ? String(t.dropLast()) : t
        guard let value = Double(number), value.isFinite, value > 0 else { return nil }
        let hours = t.hasSuffix("m") ? value / 60 : value
        guard hours > 0 else { return nil }
        return min(hours, 24)
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
        guard !app.args.has("json"), isatty(STDIN_FILENO) != 0 else { throw CLIError("Review --dry-run, then add --yes to confirm") }
        print("Proceed? [y/N] ", terminator: "")
        fflush(stdout)
        guard let a = readLine(), ["y", "yes"].contains(a.lowercased()) else { print("cancelled"); return false }
        return true
    }

    /// `thermo pulse restart NAME`: quit an app like ⌘Q, wait until it has gone, open it again.
    /// The app restores its own windows and tabs; what it had piled up in memory is freed.
    func actionOutput(_ text: String) { if !app.args.has("json") { print(text) } }
    func preview(_ hog: MachinePulse.Hog, action: String) {
        struct Plan: Encodable { let dryRun = true; let action: String; let program: MachinePulse.Hog; let verification: String }
        print(Export.json(Plan(action: action, program: hog, verification: "Execution rechecks process identity, then observes the result; unsaved work may prevent quit.")))
    }

    func restart(_ targets: [String]) throws {
        guard targets.count == 1, let target = targets.first else { throw CLIError("usage: thermo pulse restart NAME|PID [--dry-run] [--yes] [--json]") }
        let style = app.style
        var h = try pick(target)
        guard h.quittable, let path = h.app else {
            throw CLIError("\(h.name) can't be restarted from here (not an app, a system process, an AI agent session or Thermo)")
        }
        if app.args.has("dry-run") { preview(h, action: "restart"); return }
        actionOutput(style.bold("About to restart \(h.name)") + style.dim("  \(Self.size(h.memoryKB))" + (h.uptime.map { " · running " + Self.duration($0) } ?? "")))
        let windows = BrowserSession.windows(for: h.name)
        actionOutput("  quit \(path)  (like ⌘Q; it may ask to save)")
        actionOutput("  open \(path)")
        if windows == .thermoReopensTabs { actionOutput("  reopen its tabs  (saved to \(BrowserSession.backupURL().path))") }
        actionOutput("  " + style.yellow(MachinePulse.restartNote(windows)))
        guard try confirm() else { return }
        let originalID = h.id
        h = try pick(target)
        guard h.id == originalID, h.quittable else { throw CLIError("program changed since confirmation; check again") }
        let before = MachinePulse.sample()
        var saved: BrowserSession.Saved?
        if windows == .thermoReopensTabs {
            // Without the tab list, quitting would lose them: don't.
            guard let s = BrowserSession.save(app: h.name) else {
                throw CLIError("could not list \(h.name)'s tabs (allow Automation in System Settings → Privacy & Security); nothing was restarted")
            }
            saved = s
            actionOutput(style.dim("  saved \(s.tabCount) tabs in \(s.windows.count) windows"))
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
            actionOutput("Reopen request sent to \(h.name); reopened \(saved.tabCount) tabs")
            try review(h, before: before, action: .restart)
            return
        }
        actionOutput("Reopen request sent to \(h.name)")
        try review(h, before: before, action: .restart)
    }

    /// Confirm the action's effect separately from successfully sending a quit/open request.
    func review(_ hog: MachinePulse.Hog, before: MachinePulse, action: PulseActionReview.Action) throws {
        actionOutput(app.style.dim(tr("Checking the effect of the action…")))
        Thread.sleep(forTimeInterval: 5)
        let after = MachinePulse.sample()
        let inventory = MachinePulse.group(ProcessTable.current(.init(cpu: false)).entries, byMemory: true, limit: nil)
        let result = PulseActionReview(action: action, target: hog, before: before, after: after,
                                       afterTarget: PulseActionReview.findTarget(hog, in: inventory), inventoryAvailable: !inventory.isEmpty)
        result.record()
        if app.args.has("json") { print(Export.json(result)) }
        if [.unavailable, .stillRunning, .notReopened].contains(result.outcome) {
            throw CLIError(result.summary, exitCode: 3)
        }
        actionOutput(result.summary)
        actionOutput(app.style.dim(result.detail))
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
        guard s.isFinite else { return "—" }
        let seconds = max(0, s)
        func integer(_ value: Double) -> String { String(format: "%g", value.rounded(.towardZero)) }
        if seconds >= 86400 {
            return tr("%1$@d %2$@h", integer(seconds / 86400), integer(seconds.truncatingRemainder(dividingBy: 86400) / 3600))
        }
        return seconds >= 3600 ? tr("%1$@h", integer(seconds / 3600)) : tr("%1$@m", integer(seconds / 60))
    }

    func quit(_ targets: [String]) throws {
        guard targets.count == 1, let target = targets.first else { throw CLIError("usage: thermo pulse quit NAME|PID [--dry-run] [--yes] [--json]") }
        let style = app.style
        var h = try pick(target)
        guard h.quittable else {
            throw CLIError("\(h.name) is not offered for quitting (system process, AI agent session or Thermo itself)")
        }
        if app.args.has("dry-run") { preview(h, action: "quit"); return }
        let plan = h.app.map { "quit \($0)  (like ⌘Q; it may ask to save)" }
            ?? "kill -TERM " + h.pids.map(String.init).joined(separator: " ")
        actionOutput(style.bold("About to stop \(h.name)") + style.dim(String(format: "  %.0f%% CPU · %@", h.cpu, Self.size(h.memoryKB))))
        actionOutput("  " + plan)
        guard try confirm() else { return }
        let originalID = h.id
        h = try pick(target)
        guard h.id == originalID, h.quittable else { throw CLIError("program changed since confirmation; check again") }
        let before = MachinePulse.sample()
        if let path = h.app {
            try quitApp(path, name: h.name)
        } else {
            for pid in h.pids where pid != getpid() { kill(pid, SIGTERM) }
        }
        actionOutput(style.green("✓") + " asked \(h.name) to stop")
        try review(h, before: before, action: .quit)
    }
}

