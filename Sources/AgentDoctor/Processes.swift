import Foundation

struct ProcessRow: Equatable {
    var pid: Int32
    var ppid: Int32
    var cpu: Double
    var rssKB: Int
    var elapsed: TimeInterval
    var args: String
}

enum Processes {
    /// Parses `ps -axo pid=,ppid=,pcpu=,rss=,etime=,args=`.
    static func parse(_ text: String) -> [ProcessRow] {
        text.split(separator: "\n").compactMap { line in
            var rest = Substring(line)
            var fields: [Substring] = []
            for _ in 0..<5 {
                rest = rest.drop { $0 == " " }
                guard let end = rest.firstIndex(of: " ") else { return nil }
                fields.append(rest[..<end])
                rest = rest[end...]
            }
            guard let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { return nil }
            return ProcessRow(pid: pid, ppid: ppid, cpu: Double(fields[2]) ?? 0, rssKB: Int(fields[3]) ?? 0,
                              elapsed: elapsed(String(fields[4])), args: rest.trimmingCharacters(in: .whitespaces))
        }
    }

    /// `[[dd-]hh:]mm:ss`
    static func elapsed(_ s: String) -> TimeInterval {
        var days = 0.0
        var clock = Substring(s)
        if let dash = s.firstIndex(of: "-") { days = Double(s[..<dash]) ?? 0; clock = s[s.index(after: dash)...] }
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        let secs = parts.reversed().enumerated().reduce(0.0) { $0 + $1.element * pow(60, Double($1.offset)) }
        return days * 86400 + secs
    }

    static let interpreters: Set<String> = ["node", "python", "python3", "bun", "deno", "ruby", "uv", "uvx", "npx", "npm", "java", "cs-python"]
    static let markers = ["/.claude/", "/.codex/", "/.agents/", "/.cursor/", "/.gemini/", "claude", "codex", "mcp", "statusbar", "anthropic", "openai"]

    static func isAgentRelated(_ args: String, serverCommands: Set<String>) -> Bool {
        let l = args.lowercased()
        if markers.contains(where: { l.contains($0) }) { return true }
        let first = Shell.words(args).first ?? ""
        return serverCommands.contains(first) || serverCommands.contains((first as NSString).lastPathComponent)
    }

    /// A stable name for "the same program": interpreter + script, or binary + subcommand.
    static func groupName(_ args: String, executable: String?) -> String {
        let words = Shell.words(args)
        let exePath = executable ?? words.first ?? args
        // Claude Code runs from a versioned binary (…/versions/2.1.295); argv[0] still says claude.
        if ((words.first ?? "") as NSString).lastPathComponent == "claude" { return "claude" }
        var base = (exePath as NSString).lastPathComponent
        // Bundled apps: name by the bundle, not the generic helper binary.
        if let r = exePath.range(of: ".app/Contents/") {
            let bundle = (String(exePath[..<r.lowerBound]) as NSString).lastPathComponent
            if bundle != base { base = bundle + " › " + base }
        }
        let rest = words.dropFirst()
        if interpreters.contains((exePath as NSString).lastPathComponent.lowercased()),
           let script = rest.first(where: { !$0.hasPrefix("-") && ($0.contains("/") || $0.hasSuffix(".js") || $0.hasSuffix(".mjs") || $0.hasSuffix(".py")) }) {
            let comps = script.split(separator: "/").suffix(3).joined(separator: "/")
            return (exePath as NSString).lastPathComponent.lowercased() + " " + comps
        }
        if let sub = rest.first, !sub.hasPrefix("-"), !sub.contains("/"), sub.count <= 24 {
            return base + " " + sub
        }
        return base
    }
}

extension ConfigChecks {
    mutating func checkProcesses() -> (groups: [ProcessGroup], sessions: Int) {
        guard let ps = env.run("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,rss=,etime=,args="]) else { return ([], 0) }
        let launchdPids = env.run("/bin/launchctl", ["print", "gui/\(env.uid)"]).map(Launchd.servicePids) ?? [:]
        let me = getpid()
        var serverCommands = Set<String>()
        for s in servers where !s.disabled {
            guard let c = s.command else { continue }
            serverCommands.insert(env.expand(c))
            serverCommands.insert((c as NSString).lastPathComponent)
        }
        serverCommands.subtract(Processes.interpreters)

        struct Member { var row: ProcessRow; var exe: String?; var detached: Bool; var stale: Bool }
        var groups: [String: [Member]] = [:]
        var sessions = 0
        for row in Processes.parse(ps) where row.pid != me {
            guard Processes.isAgentRelated(row.args, serverCommands: serverCommands) else { continue }
            // proc_pidpath fails once the binary is deleted; argv[0] still names it.
            let argv0 = Shell.words(row.args).first
            let exe = env.executablePath(row.pid) ?? (argv0?.hasPrefix("/") == true ? argv0 : nil)
            let name = Processes.groupName(row.args, executable: exe)
            if name == "claude" { sessions += 1 }
            let detached = row.ppid == 1 && launchdPids[row.pid] == nil && !(exe ?? "").contains(".app/Contents/MacOS/")
            let stale = exe.map { $0.hasPrefix("/") && !env.exists($0) } ?? false
            groups[name, default: []].append(Member(row: row, exe: exe, detached: detached, stale: stale))
        }

        var summary: [ProcessGroup] = []
        for (name, members) in groups {
            let rss = Double(members.reduce(0) { $0 + $1.row.rssKB }) / 1024
            let cpu = members.reduce(0) { $0 + $1.row.cpu }
            let detached = members.filter(\.detached)
            summary.append(ProcessGroup(name: name, count: members.count, detached: detached.count, cpu: cpu, rssMB: rss,
                                        oldest: members.map(\.row.elapsed).max() ?? 0))

            let stale = members.filter(\.stale)
            if !stale.isEmpty {
                add(Finding(.warning, .processes, agent: "system", subject: name,
                            "\(stale.count) process\(stale.count == 1 ? "" : "es") still running a binary that was deleted or upgraded (\(env.short(stale[0].exe ?? "?"))); "
                                + "they hold \(Self.mb(stale.reduce(0) { $0 + $1.row.rssKB })) and will never pick up fixes",
                            fix: "kill \(stale.prefix(12).map { String($0.row.pid) }.joined(separator: " "))\(stale.count > 12 ? " …" : "")"))
            }
            let loose = detached.filter { !$0.stale }
            if !loose.isEmpty {
                let oldest = loose.map(\.row.elapsed).max() ?? 0
                let many = loose.count >= 3 || oldest > 86400
                add(Finding(many ? .warning : .info, .processes, agent: "system", subject: name,
                            "\(loose.count) detached process\(loose.count == 1 ? "" : "es") (parent exited; not managed by launchd), oldest started \(Self.ago(oldest)), "
                                + "\(Self.mb(loose.reduce(0) { $0 + $1.row.rssKB })) total" + (many ? " — likely leaked by sessions that ended" : ""),
                            fix: "kill \(loose.prefix(12).map { String($0.row.pid) }.joined(separator: " "))\(loose.count > 12 ? " …" : "")"))
            }
            for m in members where m.row.cpu >= 90 && name != "claude" && !name.hasPrefix("codex") {
                add(Finding(.warning, .processes, agent: "system", subject: name,
                            "pid \(m.row.pid) is using \(Int(m.row.cpu))% CPU — a busy loop in a helper heats the Mac and drains battery",
                            fix: "sample \(m.row.pid) 5   # see what it is doing; kill \(m.row.pid) if it is stuck"))
            }
            // One stdio MCP server per session adds up.
            if members.count >= 10, name != "claude", !name.hasPrefix("codex"), members.contains(where: { Processes.isMCP($0.row.args, serverCommands: serverCommands) }) {
                add(Finding(rss >= 2048 ? .warning : .info, .processes, agent: "system", subject: name,
                            "\(members.count) copies running (each agent session starts its own), \(Self.mb(Int(rss * 1024))) total",
                            fix: sessions > 0 ? "\(sessions) Claude sessions are open; closing idle ones frees their servers. A server that supports HTTP can be shared instead." : nil))
            }
        }
        summary.sort { $0.rssMB > $1.rssMB }
        return (summary, sessions)
    }

    static func mb(_ kb: Int) -> String {
        kb >= 1024 * 1024 ? String(format: "%.1f GB", Double(kb) / 1_048_576) : "\(kb / 1024) MB"
    }
}

extension Processes {
    static func isMCP(_ args: String, serverCommands: Set<String>) -> Bool {
        if args.lowercased().contains("mcp") { return true }
        let first = Shell.words(args).first ?? ""
        return serverCommands.contains(first) || serverCommands.contains((first as NSString).lastPathComponent)
    }
}
