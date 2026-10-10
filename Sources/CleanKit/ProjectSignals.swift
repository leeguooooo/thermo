import Foundation

/// When each project folder was last *used*, and by what. File modification times alone mislead
/// (a `git pull` makes a dead project look fresh; a day of agent work may change nothing on disk),
/// so the evidence comes from the tools people actually work through: AI agent sessions, editor
/// workspaces and git. The same folders also tell the project scan where to look.
public struct ProjectSignals: Sendable {
    public struct Use: Sendable, Equatable {
        public var date: Date
        /// "Claude Code", "Codex", "Cursor", "VS Code", "git" …
        public var source: String
    }

    /// Folder → most recent use recorded for exactly that folder.
    public private(set) var uses: [String: Use] = [:]

    public init(uses: [String: Use] = [:]) { self.uses = uses }

    mutating func record(_ dir: String, _ date: Date, _ source: String) {
        let d = dir.hasSuffix("/") && dir.count > 1 ? String(dir.dropLast()) : dir
        if let u = uses[d], u.date >= date { return }
        uses[d] = Use(date: date, source: source)
    }

    /// Folders worth searching for projects: inside the home folder, still present, not temp space.
    public func roots(home: String) -> [String] {
        uses.keys.filter { $0.hasPrefix(home + "/") && !$0.contains("/Library/") && FS.isDirectory($0) }.sorted()
    }

    /// The latest use of `project`, of a folder inside it, or of the folder that contains it
    /// (an agent started in the repository root uses its packages too).
    public func lastUse(of project: String) -> Use? {
        var best: Use?
        for (dir, use) in uses where dir == project || dir.hasPrefix(project + "/") || project.hasPrefix(dir + "/") {
            // A session in a parent folder (~/code, ~/test) says nothing about each project in it.
            // Only the repository root counts, for packages inside one repository.
            if project.hasPrefix(dir + "/"), !Self.isRepoRoot(dir, containing: project) { continue }
            if use.date > (best?.date ?? .distantPast) { best = use }
        }
        return best
    }

    /// True when `dir` is a git repository and `project` sits in it without a repository of its own
    /// in between.
    static func isRepoRoot(_ dir: String, containing project: String) -> Bool {
        guard FS.exists(dir + "/.git") else { return false }
        var p = (project as NSString).deletingLastPathComponent
        if FS.exists(project + "/.git") { return false }
        while p.count > dir.count {
            if FS.exists(p + "/.git") { return false }
            p = (p as NSString).deletingLastPathComponent
        }
        return true
    }

    // MARK: collecting

    public static func collect(home: String) -> ProjectSignals {
        var s = ProjectSignals()
        claude(home: home, into: &s)
        codex(home: home, into: &s)
        editors(home: home, into: &s)
        return s
    }

    /// `~/.claude/projects/<dir>/*.jsonl`: the newest transcript's `cwd`, dated by its mtime.
    static func claude(home: String, into s: inout ProjectSignals) {
        for dir in FS.children(home + "/.claude/projects") where FS.isDirectory(dir) {
            let newest = FS.children(dir).filter { $0.hasSuffix(".jsonl") }
                .compactMap { f in FS.mtime(f).map { (f, $0) } }.max { $0.1 < $1.1 }
            guard let (file, date) = newest, let cwd = AISessions.jsonString(in: file, key: "cwd") else { continue }
            s.record(cwd, date, "Claude Code")
        }
    }

    /// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`: newest first, one `cwd` read per file
    /// until every folder has its latest date.
    static func codex(home: String, into s: inout ProjectSignals) {
        let root = home + "/.codex/sessions"
        guard let e = FileManager.default.enumerator(atPath: root) else { return }
        var files: [(String, Date)] = []
        while let rel = e.nextObject() as? String {
            guard rel.hasSuffix(".jsonl") else { continue }
            let f = root + "/" + rel
            if let m = FS.mtime(f) { files.append((f, m)) }
        }
        var seen = Set<String>()
        for (f, m) in files.sorted(by: { $0.1 > $1.1 }) {
            guard let cwd = AISessions.codexMeta(f).cwd, seen.insert(cwd).inserted else { continue }
            s.record(cwd, m, "Codex")
        }
    }

    /// VS Code family `workspaceStorage/<hash>/workspace.json` → folder; dated by the state file.
    static func editors(home: String, into s: inout ProjectSignals) {
        for (app, name) in AISessions.editors {
            let root = home + "/Library/Application Support/\(app)/User/workspaceStorage"
            for ws in FS.children(root) where FS.isDirectory(ws) {
                guard let data = FileManager.default.contents(atPath: ws + "/workspace.json"),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let uri = obj["folder"] as? String, let url = URL(string: uri), url.isFileURL else { continue }
                let date = [ws + "/state.vscdb", ws + "/workspace.json"].compactMap(FS.mtime).max()
                if let date { s.record(url.path, date, name) }
            }
        }
    }

    /// Last entry of `.git/logs/HEAD` (commit, checkout, merge, pull), read straight from the file.
    public static func gitActivity(_ repo: String) -> Date? {
        let log = repo + "/.git/logs/HEAD"
        guard let h = FileHandle(forReadingAtPath: log) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 4096 ? size - 4096 : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8),
              let last = text.split(separator: "\n").last else { return nil }
        // "<old> <new> Name <email> <unix time> <tz>\t<message>"
        let head = last.split(separator: "\t", maxSplits: 1).first ?? last
        let parts = head.split(separator: " ")
        guard parts.count >= 2, let t = TimeInterval(parts[parts.count - 2]) else { return nil }
        return Date(timeIntervalSince1970: t)
    }
}
