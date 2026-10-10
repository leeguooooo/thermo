import Foundation
import ThermoL10n

struct LaunchJob {
    var label: String
    var plist: String
    var program: String?
    /// Programs a `sh -c "…"` job runs; launchd only sees the shell.
    var scriptPrograms: [String] = []
    var keepAlive: KeepAlive
    /// Jobs that run on a timer or on file changes legitimately rack up many runs.
    var scheduled: Bool
    var logs: [String]
    var disabled: Bool

    enum KeepAlive: Equatable { case none, always, conditional }
}

struct LaunchState: Equatable {
    var state: String?
    var runs: Int?
    var lastExit: String?
    var pid: Int32?
}

/// What the tail of a log looks like.
struct LogSummary: Equatable {
    var size: Int
    var modified: Date
    var lines: Int
    var topLine: String
    var topFraction: Double
}

enum Launchd {
    static func job(plist url: URL) -> LaunchJob? {
        guard let data = try? Data(contentsOf: url),
              let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = d["Label"] as? String else { return nil }
        let argv = d["ProgramArguments"] as? [String] ?? []
        let program = (d["Program"] as? String) ?? argv.first
        var scriptPrograms: [String] = []
        if let p = program, ["sh", "bash", "zsh"].contains((p as NSString).lastPathComponent),
           let flag = argv.dropFirst().first, flag.hasPrefix("-"), flag.contains("c"), argv.count > 2 {
            scriptPrograms = Shell.programs(argv[2])
        }
        let keep: LaunchJob.KeepAlive
        switch d["KeepAlive"] {
        case let b as Bool: keep = b ? .always : .none
        case is [String: Any]: keep = .conditional
        default: keep = .none
        }
        let scheduled = d["StartInterval"] != nil || d["StartCalendarInterval"] != nil || d["WatchPaths"] != nil
            || d["QueueDirectories"] != nil || d["StartOnMount"] != nil
        let logs = [d["StandardErrorPath"], d["StandardOutPath"]].compactMap { $0 as? String }
        return LaunchJob(label: label, plist: url.path, program: program, scriptPrograms: scriptPrograms, keepAlive: keep, scheduled: scheduled,
                         logs: Array(Set(logs)).sorted(), disabled: (d["Disabled"] as? Bool) == true)
    }

    /// Parses `launchctl print gui/<uid>/<label>`.
    static func state(_ text: String) -> LaunchState {
        var s = LaunchState()
        // Only the job's own top-level keys (one tab deep); nested blocks repeat "state =".
        for raw in text.split(separator: "\n") {
            guard raw.hasPrefix("\t"), !raw.hasPrefix("\t\t") else { continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.range(of: " = ") else { continue }
            let k = line[..<eq.lowerBound], v = String(line[eq.upperBound...])
            switch k {
            case "state": s.state = v
            case "runs": s.runs = Int(v)
            case "last exit code": s.lastExit = v
            case "pid": s.pid = Int32(v)
            default: break
            }
        }
        return s
    }

    /// PIDs owned by launchd jobs, from the `services = { pid status label }` table of `launchctl print gui/<uid>`.
    static func servicePids(_ text: String) -> [Int32: String] {
        var out: [Int32: String] = [:]
        var inServices = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "services = {" { inServices = true; continue }
            guard inServices else { continue }
            if line == "}" { break }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 3, let pid = Int32(parts[0]), pid > 0 { out[pid] = String(parts[2]) }
        }
        return out
    }

    /// Looks at the last 64 KB: a log that is mostly one repeated line is the trace of a restart or retry loop.
    static func summarize(log path: String) -> LogSummary? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.intValue, size > 0,
              let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let window: UInt64 = 64 * 1024
        let start = UInt64(size) > window ? UInt64(size) - window : 0
        try? fh.seek(toOffset: start)
        let data = fh.readDataToEndOfFile()
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if start > 0, !lines.isEmpty { lines.removeFirst() }  // partial line
        lines = lines.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        // Timestamps and pids make otherwise identical lines differ.
        let normalized = lines.map(normalize)
        var counts: [String: Int] = [:]
        for l in normalized { counts[l, default: 0] += 1 }
        let top = counts.max { $0.value < $1.value }!
        let original = lines[normalized.firstIndex(of: top.key)!]
        return LogSummary(size: size, modified: attrs[.modificationDate] as? Date ?? .distantPast, lines: lines.count,
                          topLine: String(original.prefix(160)), topFraction: Double(top.value) / Double(lines.count))
    }

    static let digits = try! NSRegularExpression(pattern: "[0-9]+")

    static func normalize(_ line: String) -> String {
        digits.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "#")
    }
}

extension ConfigChecks {
    /// Every per-user LaunchAgent: a broken one keeps respawning (CPU, heat) or silently does nothing.
    mutating func checkLaunchAgents() {
        let dir = env.url("Library/LaunchAgents")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for f in files.sorted() where f.hasSuffix(".plist") {
            guard !env.cancelled() else { return }
            guard let job = Launchd.job(plist: dir.appendingPathComponent(f)), !job.disabled else { continue }
            inventory.launchAgents += 1
            let plist = env.short(job.plist)
            let printed = env.run("/bin/launchctl", ["print", "gui/\(env.uid)/\(job.label)"])
            let st = printed.map(Launchd.state)
            let stateText = printed == nil ? tr("not loaded or could not be read")
                : [st?.state.map(Self.stateName), st?.runs.map { tr("%1$@ runs", String($0)) },
                   st?.lastExit.flatMap { $0.hasPrefix("(never") ? nil : tr("last exit %1$@", $0) }].compactMap { $0 }.joined(separator: " · ")
            item(.launchd, agent: "system", id: job.label, name: job.label, detail: stateText, source: plist)
            defer { currentItem = nil }
            let remove: [Step] = [.bootout(label: job.label), .trash(path: job.plist)]

            let missing = ([job.program].compactMap { $0 }.filter { $0.hasPrefix("/") }
                           + job.scriptPrograms.map { env.expand($0) }.filter { !$0.contains("$") && $0.contains("/") })
                .first { !env.exists($0) }
            if let program = missing {
                add(Finding(printed == nil ? .warning : .error, .launchd, agent: "system", subject: job.label,
                            job.keepAlive == .none
                                ? tr("program %1$@ no longer exists (left behind by an upgrade or uninstall?)", env.short(program))
                                : tr("program %1$@ no longer exists (left behind by an upgrade or uninstall?); launchd retries it forever", env.short(program)),
                            fix: tr("remove the job, or reinstall the tool it belonged to"), source: plist))
                offer(.fix, tr("Remove job"), tr("Stops %1$@ and moves its plist to the Trash; its program is already gone.", job.label),
                      remove, destructive: true)
                continue
            }

            let runs = st?.runs ?? 0
            let failing = st?.lastExit.map { $0 != "0" && !$0.hasPrefix("(never") } ?? false
            let running = st?.state == "running"
            let repairKeepAlive: [Step] = [.keepAliveOnFailure(plist: job.plist, label: job.label)]
            var activeLoop = false
            if !job.scheduled, job.keepAlive != .none, runs >= 25 {
                activeLoop = true
                add(Finding(running && !failing ? .warning : .error, .launchd, agent: "system", subject: job.label,
                            tr("restarted %1$@ times since it was loaded — it keeps exiting and launchd keeps respawning it. Last exit: %2$@.",
                               String(runs), st?.lastExit ?? "?"),
                            fix: job.keepAlive == .always
                                ? tr("KeepAlive = true respawns even on a clean exit; use KeepAlive = { SuccessfulExit = false } and fix why it exits (see its log)")
                                : tr("check its log for why it exits"),
                            source: plist))
                if job.keepAlive == .always {
                    offer(.fix, tr("Stop restart loop"),
                          tr("Changes KeepAlive so launchd only restarts %1$@ after a crash, not after a clean exit, and reloads it. The plist is backed up first. If a tool such as brew services rewrites the plist later, run this again.", job.label),
                          repairKeepAlive)
                }
            } else if failing, !running, job.keepAlive != .none {
                add(Finding(.warning, .launchd, agent: "system", subject: job.label,
                            tr("not running; last exit %1$@", st?.lastExit ?? "?"),
                            fix: tr("see its log, then: launchctl kickstart -k gui/%1$@/%2$@", String(env.uid), job.label), source: plist))
            }

            for log in job.logs {
                guard !env.cancelled() else { return }
                let path = env.expand(log)
                guard let sum = Launchd.summarize(log: path) else { continue }
                let mb = Double(sum.size) / 1_048_576
                let recent = env.now.timeIntervalSince(sum.modified) < 600
                let size = String(format: "%.1f MB", mb)
                if sum.lines >= 200, sum.topFraction >= 0.8 {
                    let percent = String(Int(sum.topFraction * 100))
                    let loopy = job.keepAlive == .always && !job.scheduled
                    if activeLoop { continue }  // already reported above
                    let when = recent ? tr("still being written") : tr("last written %1$@", Self.ago(env.now.timeIntervalSince(sum.modified)))
                    add(Finding(recent ? .warning : .info, .launchd, agent: "system", subject: job.label,
                                loopy
                                    ? tr("%1$@%% of its log is one repeated line: \"%2$@\" (%3$@, %4$@). With KeepAlive = true this is a respawn loop: each start exits and launchd starts it again",
                                         percent, sum.topLine, size, when)
                                    : tr("%1$@%% of its log is one repeated line: \"%2$@\" (%3$@, %4$@)", percent, sum.topLine, size, when),
                                fix: loopy ? tr("use KeepAlive = { SuccessfulExit = false } so a clean exit stays exited, then clear the log")
                                           : tr("clear the log"),
                                source: env.short(path)))
                    if loopy {
                        offer(.fix, tr("Stop restart loop"),
                              tr("Changes KeepAlive so launchd only restarts %1$@ after a crash, not after a clean exit, reloads it, and clears %2$@. The plist is backed up first.",
                                 job.label, env.short(path)),
                              repairKeepAlive + [.truncate(path: path)])
                    } else {
                        offer(.fix, tr("Clear log"), tr("Empties %1$@ (%2$@).", env.short(path), size), [.truncate(path: path)])
                    }
                } else if mb >= 100 {
                    add(Finding(.warning, .launchd, agent: "system", subject: job.label,
                                tr("log is %1$@ and never rotated", size), fix: tr("clear the log"), source: env.short(path)))
                    offer(.fix, tr("Clear log"), tr("Empties %1$@ (%2$@).", env.short(path), size), [.truncate(path: path)])
                }
            }
            offer(.uninstall, tr("Remove job"), tr("Stops %1$@ and moves its plist to the Trash. The program itself is not deleted.", job.label), remove)
        }
    }

    /// launchd's job states in words.
    static func stateName(_ s: String) -> String {
        switch s {
        case "running": return tr("running")
        case "not running": return tr("not running")
        case "spawn scheduled": return tr("waiting to restart")
        case "waiting": return tr("waiting")
        default: return s
        }
    }

    static func ago(_ s: TimeInterval) -> String {
        s < 3600 ? tr("%1$@ min ago", String(Int(s / 60))) : s < 86400 * 2 ? tr("%1$@ h ago", String(Int(s / 3600)))
            : tr("%1$@ days ago", String(Int(s / 86400)))
    }
}
