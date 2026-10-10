import CryptoKit
import Foundation

/// Shared state for one scan.
struct ScanContext {
    let options: ScanOptions
    let now: Date
    let processes: ProcessTable
    /// Working directories of running AI agents.
    let agentDirs: Set<String>
    /// Claude Code sessions whose process is alive (`~/.claude/sessions/<pid>.json`).
    let liveClaudeSessions: Set<String>
    /// When those live Claude Code processes started (they keep using the plugin versions of that moment).
    var liveClaudeStarts: [Date] = []

    var home: String { options.home }
    var staleBefore: Date { now.addingTimeInterval(-Double(options.olderThanDays) * 86400) }
    /// Sessions written this recently are treated as open, whatever else we know.
    var activeAfter: Date { now.addingTimeInterval(-2 * 3600) }

    func path(_ p: String) -> String { FS.expand(p, home: home) }
    func tilde(_ p: String) -> String { FS.tilde(p, home: home) }
}

/// One conversation transcript plus the files the tool keeps beside it.
struct SessionFile {
    let id: String
    let paths: [String]
    let size: TreeSize
    let modified: Date
    var title: String? = nil
}

/// Sessions of one tool grouped by the project they ran in.
struct SessionGroup {
    var cwd: String?
    var label: String
    var sessions: [SessionFile] = []
    var titles: [String] = []
}

enum AISessions {
    static func scan(_ ctx: ScanContext) -> [CleanItem] {
        var items: [CleanItem] = []
        items += claudeCode(ctx)
        items += codex(ctx)
        items += gemini(ctx)
        items += editorTasks(ctx)
        items += editorWorkspaces(ctx)
        items += opencode(ctx)
        return items
    }

    // MARK: grouping → items

    /// Turns per-project session groups into items holding the stale sessions.
    static func items(tool: String, idPrefix: String, groups: [SessionGroup], ctx: ScanContext) -> [CleanItem] {
        var out: [CleanItem] = []
        for g in groups {
            let projectGone = g.cwd.map { !FS.exists($0) } ?? false
            let agentHere = g.cwd.map { ctx.agentDirs.contains($0) } ?? false
            let newest = g.sessions.map(\.modified).max()
            var stale: [SessionFile] = []
            var kept: [SessionFile] = []
            var live = 0
            for s in g.sessions {
                let active = s.modified > ctx.activeAfter || (agentHere && s.modified == newest)
                    || ctx.liveClaudeSessions.contains(s.id)
                if active { live += 1; kept.append(s) }
                else if s.modified < ctx.staleBefore || projectGone { stale.append(s) }
                else { kept.append(s) }
            }
            guard !stale.isEmpty else { continue }
            let size = stale.reduce(TreeSize()) { $0 + $1.size }
            var detail = g.cwd.map(ctx.tilde) ?? g.label
            if projectGone { detail += " · " + tr("project folder deleted") }
            var notes: [String] = []
            if !kept.isEmpty {
                let keptSize = kept.reduce(Int64(0)) { $0 + $1.size.bytes }
                notes.append(live > 0
                    ? trCount(kept.count, "keeping %1$@ recent session (%2$@), %3$@ in use", "keeping %1$@ recent sessions (%2$@), %3$@ in use",
                              ByteFormat.string(keptSize), String(live))
                    : trCount(kept.count, "keeping %1$@ recent session (%2$@)", "keeping %1$@ recent sessions (%2$@)",
                              ByteFormat.string(keptSize)))
            }
            let titles = stale.sorted { $0.modified > $1.modified }.compactMap(\.title).filter { !$0.isEmpty }
            if let t = titles.first ?? g.titles.first { notes.append(tr("latest: “%1$@”", String(t.prefix(60)))) }
            out.append(CleanItem(
                id: "\(idPrefix)/\(slug(g.cwd.map { relative($0, ctx) } ?? g.label))", category: .aiSessions,
                title: "\(tool) · \(g.label) · " + trCount(stale.count, "%1$@ session", "%1$@ sessions"),
                detail: detail, safety: .review, bytes: size.bytes, files: size.files,
                lastUsed: stale.map(\.modified).max(), paths: stale.flatMap(\.paths),
                note: notes.isEmpty ? nil : notes.joined(separator: tr("; ")),
                parts: stale.sorted { $0.modified > $1.modified }.map {
                    CleanPart(id: $0.id, title: $0.title.map { String($0.prefix(80)) } ?? ($0.id as NSString).lastPathComponent, bytes: $0.size.bytes,
                              lastUsed: $0.modified, paths: $0.paths)
                }))
        }
        return out
    }

    /// `/Users/leo/src/app` → `src/app`, for short ids.
    static func relative(_ path: String, _ ctx: ScanContext) -> String {
        path.hasPrefix(ctx.home + "/") ? String(path.dropFirst(ctx.home.count + 1)) : path
    }

    static func slug(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" ? $0 : "-" })
    }

    static func label(for cwd: String?, fallback: String) -> String {
        guard let cwd, !cwd.isEmpty else { return fallback }
        let last = (cwd as NSString).lastPathComponent
        // Scratch directories of agents are only identifiable by their parent project.
        if cwd.hasPrefix("/private/tmp/") || cwd.hasPrefix("/tmp/") { return tr("temp: %1$@", last) }
        return last.isEmpty ? cwd : last
    }

    // MARK: Claude Code

    /// `~/.claude/projects/<encoded cwd>/<session>.jsonl`, with sidecars in `<session>/`,
    /// `~/.claude/file-history/<session>`, `~/.claude/todos/<session>-*.json` and `~/.claude/session-env/<session>`.
    static func claudeCode(_ ctx: ScanContext) -> [CleanItem] {
        let root = ctx.path("~/.claude")
        let projects = root + "/projects"
        guard FS.isDirectory(projects) else { return [] }
        let todos = (try? FileManager.default.contentsOfDirectory(atPath: root + "/todos")) ?? []
        var todoBySession: [String: [String]] = [:]
        for t in todos { todoBySession[String(t.prefix(36)), default: []].append(root + "/todos/" + t) }

        let prompts = claudeFirstPrompts(root + "/history.jsonl")
        var groups: [SessionGroup] = []
        var allSessions = Set<String>()
        for dir in FS.children(projects) where FS.isDirectory(dir) {
            let encoded = (dir as NSString).lastPathComponent
            var g = SessionGroup(cwd: nil, label: encoded)
            var newestFile: (String, Date)?
            for f in FS.children(dir) where f.hasSuffix(".jsonl") {
                let sid = String((f as NSString).lastPathComponent.dropLast(6))
                allSessions.insert(sid)
                guard let m = FS.mtime(f) else { continue }
                var paths = [f]
                for side in [dir + "/" + sid, root + "/file-history/" + sid, root + "/session-env/" + sid]
                where FS.exists(side) { paths.append(side) }
                paths += todoBySession[sid] ?? []
                g.sessions.append(SessionFile(id: sid, paths: paths, size: FS.size(paths), modified: m))
                if m > (newestFile?.1 ?? .distantPast) { newestFile = (f, m) }
            }
            guard let (file, _) = newestFile else { continue }
            g.cwd = jsonString(in: file, key: "cwd") ?? decodeClaudeDir(encoded)
            g.label = label(for: g.cwd, fallback: encoded)
            g.sessions = g.sessions.map { var s = $0; s.title = prompts[s.id]; return s }
            groups.append(g)
        }
        var items = items(tool: "Claude Code", idPrefix: "claude-sessions", groups: groups, ctx: ctx)

        // Sidecars whose session transcript no longer exists anywhere.
        var orphans: [String] = []
        for sub in ["file-history", "session-env"] {
            for p in FS.children(root + "/" + sub) {
                let sid = (p as NSString).lastPathComponent
                if sid.count == 36, !allSessions.contains(sid), (FS.mtime(p) ?? ctx.now) < ctx.activeAfter { orphans.append(p) }
            }
        }
        for (sid, files) in todoBySession where sid.count == 36 && !allSessions.contains(sid) {
            orphans += files.filter { (FS.mtime($0) ?? ctx.now) < ctx.activeAfter }
        }
        if !orphans.isEmpty {
            let s = FS.size(orphans)
            items.append(CleanItem(id: "claude-orphans", category: .aiSessions,
                                   title: tr("Claude Code leftovers of deleted sessions"),
                                   detail: tr("file history, todos and env of sessions that no longer exist"),
                                   safety: .safe, bytes: s.bytes, files: s.files, paths: orphans))
        }
        // Backups people make of the projects folder before upgrades.
        let backups = FS.children(root).filter { ($0 as NSString).lastPathComponent.hasPrefix("projects-backup") }
        if !backups.isEmpty {
            let s = FS.size(backups, trackNewest: true)
            items.append(CleanItem(id: "claude-project-backups", category: .aiSessions, title: tr("Claude Code projects backups"),
                                   detail: backups.map { ctx.tilde($0) }.joined(separator: ", "), safety: .review,
                                   bytes: s.bytes, files: s.files, lastUsed: s.newest, paths: backups))
        }
        return items
    }

    /// sessionId → first prompt typed in it, from `~/.claude/history.jsonl` (skipping slash commands).
    static func claudeFirstPrompts(_ path: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        var out: [String: String] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let sid = obj["sessionId"] as? String, out[sid] == nil,
                  let text = obj["display"] as? String else { continue }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count >= 4, !t.hasPrefix("/") { out[sid] = t.replacingOccurrences(of: "\n", with: " ") }
        }
        return out
    }

    /// `-Users-leo-src-app` → `/Users/leo/src/app` when that folder exists. The encoding is lossy
    /// (`.` and `-` also become `-`), so this is only a fallback for transcripts without a `cwd`.
    static func decodeClaudeDir(_ encoded: String) -> String? {
        let p = encoded.replacingOccurrences(of: "-", with: "/")
        return p.hasPrefix("/") && FS.isDirectory(p) ? p : nil
    }

    /// Finds `"key":"value"` in the first 256 KB of a JSON-lines file.
    static func jsonString(in file: String, key: String) -> String? {
        guard let data = FS.head(file, limit: 256 * 1024), let text = String(data: data, encoding: .utf8)
                ?? String(data: data.prefix(data.count - 3), encoding: .utf8) else { return nil }
        let needle = "\"\(key)\":\""
        guard let r = text.range(of: needle) else { return nil }
        var value = ""
        var escaped = false
        for ch in text[r.upperBound...] {
            if escaped {
                switch ch {
                case "n": value.append("\n")
                case "t": value.append("\t")
                default: value.append(ch)
                }
                escaped = false
            } else if ch == "\\" { escaped = true }
            else if ch == "\"" { return value }
            else { value.append(ch) }
        }
        return nil
    }

    // MARK: Codex

    /// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (first line `session_meta` has `cwd`),
    /// titles from `~/.codex/session_index.jsonl`; `~/.codex/archived_sessions/` handled as one group.
    static func codex(_ ctx: ScanContext) -> [CleanItem] {
        let root = ctx.path("~/.codex")
        guard FS.isDirectory(root + "/sessions") || FS.isDirectory(root + "/archived_sessions") else { return [] }
        var titles: [String: String] = [:]
        if let data = FileManager.default.contents(atPath: root + "/session_index.jsonl"),
           let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let id = obj["id"] as? String, let name = obj["thread_name"] as? String else { continue }
                titles[id] = name
            }
        }
        var byCwd: [String: SessionGroup] = [:]
        func collect(_ dir: String, archived: Bool) {
            guard let e = FileManager.default.enumerator(atPath: dir) else { return }
            while let rel = e.nextObject() as? String {
                guard rel.hasSuffix(".jsonl") else { continue }
                let f = dir + "/" + rel
                guard let m = FS.mtime(f) else { continue }
                let meta = codexMeta(f)
                let key = archived ? "archived" : (meta.cwd ?? "unknown")
                var g = byCwd[key] ?? SessionGroup(cwd: archived ? nil : meta.cwd,
                                                   label: archived ? tr("archived") : label(for: meta.cwd, fallback: "unknown"))
                g.sessions.append(SessionFile(id: meta.id ?? rel, paths: [f], size: FS.size(f), modified: m,
                                              title: meta.id.flatMap { titles[$0] }))
                byCwd[key] = g
            }
        }
        collect(root + "/sessions", archived: false)
        collect(root + "/archived_sessions", archived: true)
        let groups = byCwd.values.map { g -> SessionGroup in
            var g = g
            g.sessions.sort { $0.modified > $1.modified }
            return g
        }
        var items = items(tool: "Codex", idPrefix: "codex-sessions", groups: groups, ctx: ctx)
        for i in items.indices {
            items[i].note = [items[i].note, tr("Codex's thread list may still show removed threads")].compactMap { $0 }
                .joined(separator: tr("; "))
        }
        return items
    }

    static func codexMeta(_ file: String) -> (id: String?, cwd: String?) {
        guard let data = FS.head(file, limit: 16 * 1024) else { return (nil, nil) }
        let line = data.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first.map { Data($0) } ?? data
        if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
           let payload = obj["payload"] as? [String: Any] {
            return (payload["id"] as? String, payload["cwd"] as? String)
        }
        // First line larger than the read window: fall back to scanning the text.
        let tmp = String(decoding: data, as: UTF8.self)
        func field(_ k: String) -> String? {
            guard let r = tmp.range(of: "\"\(k)\":\"") else { return nil }
            return String(tmp[r.upperBound...].prefix { $0 != "\"" })
        }
        return (field("id"), field("cwd"))
    }

    // MARK: Gemini CLI

    /// `~/.gemini/tmp/<project>/{chats,logs.json,…}`; `~/.gemini/projects.json` maps paths to names.
    static func gemini(_ ctx: ScanContext) -> [CleanItem] {
        let tmp = ctx.path("~/.gemini/tmp")
        guard FS.isDirectory(tmp) else { return [] }
        var nameToPath: [String: String] = [:]
        if let data = FileManager.default.contents(atPath: ctx.path("~/.gemini/projects.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = obj["projects"] as? [String: String] {
            for (p, n) in projects { nameToPath[n] = p }
        }
        var groups: [SessionGroup] = []
        for dir in FS.children(tmp) where FS.isDirectory(dir) {
            let name = (dir as NSString).lastPathComponent
            guard name != "bin" else { continue }
            let cwd = nameToPath[name] ?? hashedCwd(name, ctx: ctx)
            let s = FS.size(dir, trackNewest: true)
            guard s.bytes > 0 else { continue }
            groups.append(SessionGroup(cwd: cwd, label: cwd.map { label(for: $0, fallback: name) } ?? name,
                                       sessions: [SessionFile(id: name, paths: [dir], size: s, modified: s.newest ?? ctx.now)]))
        }
        return items(tool: "Gemini CLI", idPrefix: "gemini-sessions", groups: groups, ctx: ctx)
    }

    /// Older Gemini CLI versions name the folder sha256(project path).
    static func hashedCwd(_ name: String, ctx: ScanContext) -> String? {
        guard name.count == 64 else { return nil }
        for root in ctx.options.projectRoots {
            for dir in FS.children(root) + [root] {
                let h = SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined()
                if h == name { return dir }
            }
        }
        return nil
    }

    // MARK: VS Code family

    static let editors = [("Code", "VS Code"), ("Cursor", "Cursor"), ("Windsurf", "Windsurf"), ("VSCodium", "VSCodium"),
                          ("Code - Insiders", "VS Code Insiders"), ("Kiro", "Kiro"), ("Trae", "Trae")]

    /// Agent extensions keep one folder per task: Cline, Roo Code, Kilo Code.
    static func editorTasks(_ ctx: ScanContext) -> [CleanItem] {
        let extensions = [("saoudrizwan.claude-dev", "Cline"), ("rooveterinaryinc.roo-cline", "Roo Code"),
                          ("kilocode.kilo-code", "Kilo Code")]
        var items: [CleanItem] = []
        for (app, appName) in editors {
            for (ext, extName) in extensions {
                let tasks = ctx.path("~/Library/Application Support/\(app)/User/globalStorage/\(ext)/tasks")
                guard FS.isDirectory(tasks) else { continue }
                var g = SessionGroup(cwd: nil, label: "\(extName) in \(appName)")
                for t in FS.children(tasks) where FS.isDirectory(t) {
                    let s = FS.size(t, trackNewest: true)
                    g.sessions.append(SessionFile(id: t, paths: [t], size: s, modified: s.newest ?? ctx.now))
                }
                items += self.items(tool: extName, idPrefix: "\(slug(extName.lowercased()))-tasks", groups: [g], ctx: ctx)
                    .map { var i = $0; i.id = "\(slug(extName.lowercased()))-tasks/\(slug(app.lowercased()))"
                        i.title = tr("%1$@ tasks in %2$@", extName, appName) + " · " + (i.title.components(separatedBy: " · ").last ?? "")
                        i.detail = FS.tilde(tasks, home: ctx.home); return i }
            }
        }
        return items
    }

    /// `User/workspaceStorage/<hash>/workspace.json` points at a folder; when that folder is gone the
    /// workspace state (including Cursor / Copilot chat history for it) is dead weight.
    static func editorWorkspaces(_ ctx: ScanContext) -> [CleanItem] {
        var items: [CleanItem] = []
        for (app, appName) in editors {
            let root = ctx.path("~/Library/Application Support/\(app)/User/workspaceStorage")
            guard FS.isDirectory(root) else { continue }
            var dead: [String] = []
            for ws in FS.children(root) where FS.isDirectory(ws) {
                guard let data = FileManager.default.contents(atPath: ws + "/workspace.json"),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let uri = (obj["folder"] ?? obj["workspace"]) as? String,
                      let url = URL(string: uri), url.isFileURL else { continue }
                if !FS.exists(url.path) { dead.append(ws) }
            }
            guard !dead.isEmpty else { continue }
            let s = FS.size(dead, trackNewest: true)
            guard s.bytes > 0 else { continue }
            items.append(CleanItem(id: "\(slug(app.lowercased()))-orphan-workspaces", category: .aiSessions,
                                   title: tr("%1$@ data for deleted folders", appName) + " · " + trCount(dead.count, "%1$@ workspace", "%1$@ workspaces"),
                                   detail: tr("chat history and editor state of projects that no longer exist"),
                                   safety: .review, bytes: s.bytes, files: s.files, lastUsed: s.newest, paths: dead,
                                   blocked: ctx.processes.running([appName == "VS Code" ? "Code" : app]).map { tr("%1$@ is running", $0) }))
        }
        return items
    }

    // MARK: opencode

    /// opencode keeps sessions in one SQLite database; we report it and clean only logs and tool output.
    static func opencode(_ ctx: ScanContext) -> [CleanItem] {
        let root = ctx.path("~/.local/share/opencode")
        guard FS.isDirectory(root) else { return [] }
        var items: [CleanItem] = []
        let db = FS.size([root + "/opencode.db", root + "/opencode.db-wal"])
        if db.bytes > 50_000_000 {
            items.append(CleanItem(id: "opencode-db", category: .aiSessions, title: tr("opencode session database"),
                                   detail: FS.tilde(root + "/opencode.db", home: ctx.home), safety: .review,
                                   bytes: db.bytes, files: db.files, lastUsed: FS.mtime(root + "/opencode.db"),
                                   note: tr("all opencode sessions live in this database"),
                                   hint: tr("delete old sessions from opencode itself (/sessions)")))
        }
        let logs = [root + "/log", root + "/tool-output"].flatMap(FS.children).filter { (FS.mtime($0) ?? ctx.now) < ctx.activeAfter }
        let s = FS.size(logs)
        if s.bytes > 0 {
            items.append(CleanItem(id: "opencode-logs", category: .aiCaches, title: tr("opencode logs & tool output"),
                                   detail: FS.tilde(root, home: ctx.home), safety: .safe, bytes: s.bytes, files: s.files,
                                   paths: logs))
        }
        return items
    }
}
