import Foundation
import ThermoL10n

/// A crash report macOS wrote for a program an agent started (an MCP server, a hook, a tool).
struct AgentCrash: Equatable {
    var file: String
    var procName: String
    var procPath: String
    var parent: String
    var reason: String
}

/// Programs an agent item runs, by the names a crash report would give them.
struct CrashKey {
    var item: String
    var area: Area
    var agent: String
    var subject: String
    var source: String?
    var names: Set<String>
}

extension ConfigChecks {
    /// `python3.14`, `Python` → `python`; `node` stays `node`.
    static func crashName(_ name: String) -> String {
        let n = (name as NSString).lastPathComponent.lowercased()
        let stem = String(n.prefix { !$0.isNumber && $0 != "." })
        return stem.isEmpty ? n : stem
    }

    /// The names a command shows up as in a crash report: the program, and the interpreter of a script.
    func crashNames(_ command: String, vars: [String: String] = [:]) -> Set<String> {
        let p = env.expand(command, vars: vars)
        guard !p.contains("$"), let resolved = env.resolve(p) else { return [] }
        var names: Set<String> = [Self.crashName(resolved)]
        if let h = FileHandle(forReadingAtPath: resolved) {
            let head = h.readData(ofLength: 256)
            try? h.close()
            if let line = String(data: head, encoding: .utf8)?.split(separator: "\n").first, line.hasPrefix("#!") {
                let words = line.dropFirst(2).split(separator: " ").map(String.init)
                let program = (words.first.map { ($0 as NSString).lastPathComponent } == "env" ? words.dropFirst().first { !$0.hasPrefix("-") } : words.first)
                if let program { names.insert(Self.crashName(program)) }
            }
        }
        return names
    }

    mutating func noteCrashKey(_ area: Area, agent: String, subject: String, source: String?, commands: [String], vars: [String: String] = [:]) {
        guard let item = currentItem else { return }
        let names = commands.reduce(into: Set<String>()) { $0.formUnion(crashNames($1, vars: vars)) }
        if !names.isEmpty { crashKeys.append(CrashKey(item: item, area: area, agent: agent, subject: subject, source: source, names: names)) }
    }

    /// Reads the crash reports of the last week whose parent was an agent.
    static func agentCrashes(in dir: URL, since: Date, cancelled: () -> Bool = { false }) -> [AgentCrash] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var out: [AgentCrash] = []
        for url in files where url.pathExtension == "ips" {
            if cancelled() { break }
            guard let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m >= since,
                  let h = try? FileHandle(forReadingFrom: url) else { continue }
            let head = String(decoding: h.readData(ofLength: 24 * 1024), as: UTF8.self)
            try? h.close()
            func field(_ key: String) -> String? {
                guard let r = head.range(of: "\"\(key)\"\\s*:\\s*\"([^\"]*)\"", options: .regularExpression) else { return nil }
                let s = head[r]
                guard let q = s.range(of: ":\\s*\"", options: .regularExpression) else { return nil }
                return String(s[q.upperBound...].dropLast()).replacingOccurrences(of: "\\/", with: "/")
            }
            guard let parent = field("parentProc"), agentParent(parent) != nil,
                  let name = field("procName"), let path = field("procPath") else { continue }
            let asi = head.range(of: "\"asi\"").flatMap { r in
                head[r.upperBound...].range(of: "\\[\"[^\"]+\"\\]", options: .regularExpression).map { String(head[$0].dropFirst(2).dropLast(2)) }
            }
            let reason = [field("indicator"), asi].compactMap { $0 }.joined(separator: "; ")
            out.append(AgentCrash(file: url.path, procName: name, procPath: path, parent: parent, reason: reason))
        }
        return out
    }

    /// The agent a crash report's parent process belongs to.
    static func agentParent(_ parent: String) -> String? {
        let p = parent.lowercased()
        for agent in ["claude", "codex", "cursor", "gemini"] where p.hasPrefix(agent) { return agent }
        return nil
    }

    /// Programs an agent started that crash again and again (each crash also leaves a report and
    /// may show the "quit unexpectedly" dialog). Tied to the MCP server or hook that runs that
    /// program when only one does.
    mutating func checkCrashes() {
        guard !env.cancelled() else { return }
        let dir = env.url("Library/Logs/DiagnosticReports")
        let crashes = Self.agentCrashes(in: dir, since: env.now.addingTimeInterval(-7 * 86400), cancelled: env.cancelled)
        let groups = Dictionary(grouping: crashes) { "\($0.procPath)|\(Self.agentParent($0.parent) ?? "")" }
        for (_, group) in groups.sorted(by: { $0.value.count > $1.value.count }) where group.count >= 2 {
            let first = group[0]
            let agent = Self.agentParent(first.parent) ?? first.parent
            let name = Self.crashName(first.procName)
            let newest = group.map(\.file).max() ?? first.file
            let candidates = crashKeys.filter { $0.agent == agent && $0.names.contains(name) }
            let why = first.reason.isEmpty ? "" : " (\(first.reason))"
            let fix = tr("see the newest report: %1$@", env.short(newest))
            if candidates.count == 1, let c = candidates.first {
                var f = Finding(.warning, c.area, agent: agent, subject: c.subject,
                                tr("its program (%1$@) crashed %2$@ times in the last 7 days%3$@", first.procName, String(group.count), why),
                                fix: fix, source: c.source)
                f.item = c.item
                findings.append(f)
            } else {
                let area = candidates.first?.area ?? .processes
                let message = candidates.isEmpty
                    ? tr("%1$@ started by %2$@ crashed %3$@ times in the last 7 days%4$@", first.procName, agent, String(group.count), why)
                    : tr("%1$@ started by %2$@ crashed %3$@ times in the last 7 days%4$@; it is one of: %5$@", first.procName, agent,
                         String(group.count), why, candidates.map(\.subject).joined(separator: ", "))
                findings.append(Finding(.warning, area, agent: agent, subject: first.procName, message, fix: fix,
                                        source: env.short(first.procPath)))
            }
        }
    }
}
