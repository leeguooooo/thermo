import Foundation
import Darwin

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
        if ScanCancellation.current?.isCancelled != true { codex(home: home, into: &s) }
        if ScanCancellation.current?.isCancelled != true { editors(home: home, into: &s) }
        return s
    }

    /// `~/.claude/projects/<dir>/*.jsonl`: the newest transcript's `cwd`, dated by its mtime.
    static func claude(home: String, into s: inout ProjectSignals) {
        for dir in FS.children(home + "/.claude/projects") where FS.isDirectory(dir) {
            guard ScanCancellation.current?.isCancelled != true else { return }
            let newest = FS.children(dir).filter { $0.hasSuffix(".jsonl") }
                .compactMap { f in FS.mtime(f).map { (f, $0) } }.max { $0.1 < $1.1 }
            guard let (file, date) = newest, let cwd = AISessions.jsonString(in: file, key: "cwd") else { continue }
            s.record(cwd, date, "Claude Code")
        }
    }

    struct SessionHeader: Codable, Equatable {
        var inode: UInt64
        var seconds: Int
        var nanoseconds: Int
        var allocated: Int64
        var cwd: String?
    }

    struct HeaderCache: Codable {
        var version = 1
        var headers: [String: SessionHeader]
    }

    /// Cache only metadata and cwd, never transcript text. Every scan enumerates current files
    /// and checks identity + nanosecond mtime; changed, replaced and new files are read afresh.
    static func codex(home: String, into s: inout ProjectSignals,
                      readCWD: (String) -> String? = { AISessions.codexMeta($0).cwd }) {
        guard ScanCancellation.current?.isCancelled != true else { return }
        let root = home + "/.codex/sessions"
        var rootStat = stat()
        guard lstat(root, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR else { return }
        let cacheURL = URL(fileURLWithPath: home + "/Library/Caches/dev.thermo/codex-project-headers.json")
        var cached: [String: SessionHeader] = [:]
        if let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 * 1024,
           let data = try? Data(contentsOf: cacheURL), data.count <= 32 * 1024 * 1024,
           let cache = try? JSONDecoder().decode(HeaderCache.self, from: data), cache.version == 1 {
            cached = cache.headers
        }
        var current: [String: SessionHeader] = [:]
        var stack = [root]
        func see(_ path: String, _ signature: SessionHeader) {
            guard path.hasSuffix(".jsonl"), ScanCancellation.current?.isCancelled != true else { return }
            let relative = String(path.dropFirst(root.count + 1))
            var header = signature
            if let old = cached[relative], old.inode == header.inode, old.seconds == header.seconds,
               old.nanoseconds == header.nanoseconds, old.allocated == header.allocated, old.cwd != nil {
                header.cwd = old.cwd
            } else {
                header.cwd = readCWD(path)
            }
            current[relative] = header
            if let cwd = header.cwd {
                let date = Date(timeIntervalSince1970: Double(header.seconds) + Double(header.nanoseconds) / 1e9)
                s.record(cwd, date, "Codex")
            }
        }
        while let dir = stack.popLast() {
            guard ScanCancellation.current?.isCancelled != true else { return }
            let ok = BulkWalk.entries(of: dir) { entry in
                guard entry.error == 0 else { return }
                let path = dir + "/" + entry.name
                if entry.isDir { stack.append(path) }
                else if entry.isFile {
                    see(path, SessionHeader(inode: entry.fileID, seconds: entry.modified,
                                            nanoseconds: entry.modifiedNanoseconds, allocated: entry.allocated))
                }
            }
            if !ok {
                // Filesystems without getattrlistbulk still get safe, no-follow traversal.
                for (name, _) in FS.entries(dir) ?? [] {
                    let path = dir + "/" + name
                    var st = stat()
                    guard lstat(path, &st) == 0 else { continue }
                    if (st.st_mode & S_IFMT) == S_IFDIR { stack.append(path) }
                    else if (st.st_mode & S_IFMT) == S_IFREG {
                        see(path, SessionHeader(inode: st.st_ino, seconds: st.st_mtimespec.tv_sec,
                                                nanoseconds: st.st_mtimespec.tv_nsec, allocated: Int64(st.st_blocks) * 512))
                    }
                }
            }
        }
        guard ScanCancellation.current?.isCancelled != true else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(HeaderCache(headers: current)), data.count <= 32 * 1024 * 1024 {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }

    /// VS Code family `workspaceStorage/<hash>/workspace.json` → folder; dated by the state file.
    static func editors(home: String, into s: inout ProjectSignals) {
        for (app, name) in AISessions.editors {
            let root = home + "/Library/Application Support/\(app)/User/workspaceStorage"
            for ws in FS.children(root) where FS.isDirectory(ws) {
                guard ScanCancellation.current?.isCancelled != true else { return }
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
