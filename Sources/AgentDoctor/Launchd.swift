import Foundation

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
            guard let job = Launchd.job(plist: dir.appendingPathComponent(f)), !job.disabled else { continue }
            inventory.launchAgents += 1
            let plist = env.short(job.plist)
            let printed = env.run("/bin/launchctl", ["print", "gui/\(env.uid)/\(job.label)"])
            let st = printed.map(Launchd.state)
            let stateText = printed == nil ? "not loaded"
                : [st?.state, st?.runs.map { "\($0) runs" }, st?.lastExit.flatMap { $0.hasPrefix("(never") ? nil : "last exit \($0)" }].compactMap { $0 }.joined(separator: " · ")
            item(.launchd, agent: "system", id: job.label, name: job.label, detail: stateText, source: plist)
            defer { currentItem = nil }

            let missing = ([job.program].compactMap { $0 }.filter { $0.hasPrefix("/") }
                           + job.scriptPrograms.map { env.expand($0) }.filter { !$0.contains("$") && $0.contains("/") })
                .first { !env.exists($0) }
            if let program = missing {
                add(Finding(printed == nil ? .warning : .error, .launchd, agent: "system", subject: job.label,
                            "program \(env.short(program)) no longer exists (left behind by an upgrade or uninstall?)"
                                + (job.keepAlive == .none ? "" : "; launchd retries it forever"),
                            fix: "launchctl bootout gui/\(env.uid)/\(job.label); rm \(plist)  — or reinstall the tool", source: plist))
                continue
            }

            let runs = st?.runs ?? 0
            let failing = st?.lastExit.map { $0 != "0" && !$0.hasPrefix("(never") } ?? false
            let running = st?.state == "running"
            var activeLoop = false
            if !job.scheduled, job.keepAlive != .none, runs >= 25 {
                activeLoop = true
                let exit = st?.lastExit.map { " Last exit: \($0)." } ?? ""
                add(Finding(running && !failing ? .warning : .error, .launchd, agent: "system", subject: job.label,
                            "restarted \(runs) times since it was loaded — it keeps exiting and launchd keeps respawning it.\(exit)",
                            fix: job.keepAlive == .always
                                ? "KeepAlive = true respawns even on a clean exit; use KeepAlive = { SuccessfulExit = false } and fix why it exits (see its log)"
                                : "check its log for why it exits",
                            source: plist))
            } else if failing, !running, job.keepAlive != .none {
                add(Finding(.warning, .launchd, agent: "system", subject: job.label,
                            "not running; last exit \(st?.lastExit ?? "?")", fix: "see its log, then: launchctl kickstart -k gui/\(env.uid)/\(job.label)",
                            source: plist))
            }

            for log in job.logs {
                let path = env.expand(log)
                guard let sum = Launchd.summarize(log: path) else { continue }
                let mb = Double(sum.size) / 1_048_576
                let recent = env.now.timeIntervalSince(sum.modified) < 600
                if sum.lines >= 200, sum.topFraction >= 0.8 {
                    let percent = Int(sum.topFraction * 100)
                    let loopy = job.keepAlive == .always && !job.scheduled
                    if activeLoop { continue }  // already reported above
                    add(Finding(recent ? .warning : .info, .launchd, agent: "system", subject: job.label,
                                "\(percent)% of its log is one repeated line: \"\(sum.topLine)\" (\(String(format: "%.1f", mb)) MB, "
                                    + (recent ? "still being written" : "last written \(Self.ago(env.now.timeIntervalSince(sum.modified)))") + ")"
                                    + (loopy ? ". With KeepAlive = true this is a respawn loop: each start exits and launchd starts it again" : ""),
                                fix: (loopy ? "use KeepAlive = { SuccessfulExit = false } so a clean exit stays exited; " : "")
                                    + "truncate with: : > \(env.short(path))",
                                source: env.short(path)))
                } else if mb >= 100 {
                    add(Finding(.warning, .launchd, agent: "system", subject: job.label,
                                "log is \(Int(mb)) MB and never rotated", fix: ": > \(env.short(path))", source: env.short(path)))
                }
            }
        }
    }

    static func ago(_ s: TimeInterval) -> String {
        s < 3600 ? "\(Int(s / 60)) min ago" : s < 86400 * 2 ? "\(Int(s / 3600)) h ago" : "\(Int(s / 86400)) days ago"
    }
}
