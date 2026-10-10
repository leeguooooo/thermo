import Foundation

/// AI tool installs that pile up: old CLI versions, plugin checkouts, runtimes, agent scratch space.
enum AITools {
    static func scan(_ ctx: ScanContext) -> [CleanItem] {
        var items: [CleanItem] = []
        items += versions(ctx)
        items += claudePlugins(ctx)
        items += claudeScratch(ctx)
        items += codexRuntimes(ctx)
        return items
    }

    /// Version folders of self-updating CLIs. Keeps the active one (launcher symlink), any version a
    /// running process was started from, and the newest; the rest are old installs.
    static func versions(_ ctx: ScanContext) -> [CleanItem] {
        let tools: [(id: String, title: String, dir: String, launcher: String?)] = [
            ("claude-cli-versions", "Claude Code old versions", "~/.local/share/claude/versions", "~/.local/bin/claude"),
            ("cursor-agent-versions", "Cursor Agent old versions", "~/.local/share/cursor-agent/versions", "~/.local/bin/cursor-agent"),
            ("copilot-cli-versions", "Copilot CLI old versions", "~/.copilot/pkg/universal", nil),
            ("claude-desktop-code-versions", "Claude desktop bundled Claude Code", "~/Library/Application Support/Claude/claude-code", nil),
        ]
        var items: [CleanItem] = []
        for t in tools {
            let dir = ctx.path(t.dir)
            let all = FS.children(dir).filter { !($0 as NSString).lastPathComponent.hasPrefix(".") }
            guard all.count > 1 else { continue }
            var keep = Set<String>()
            if let l = t.launcher, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: ctx.path(l)) {
                let abs = target.hasPrefix("/") ? target : (ctx.path(l) as NSString).deletingLastPathComponent + "/" + target
                if let v = all.first(where: { abs == $0 || abs.hasPrefix($0 + "/") }) { keep.insert(v) }
            }
            for e in ctx.processes.entries {
                guard let exe = e.executable else { continue }
                if let v = all.first(where: { exe == $0 || exe.hasPrefix($0 + "/") }) { keep.insert(v) }
            }
            if let newest = all.max(by: { compareVersions(($0 as NSString).lastPathComponent, ($1 as NSString).lastPathComponent) }) {
                keep.insert(newest)
            }
            let old = all.filter { !keep.contains($0) }
            guard !old.isEmpty else { continue }
            let s = FS.size(old)
            let names = old.map { ($0 as NSString).lastPathComponent }.sorted { compareVersions($0, $1) }
            items.append(CleanItem(id: t.id, category: .aiCaches, title: "\(t.title) · \(old.count)",
                                   detail: names.joined(separator: ", "), safety: .safe, bytes: s.bytes, files: s.files,
                                   paths: old, note: "keeping \(keep.map { ($0 as NSString).lastPathComponent }.sorted().joined(separator: ", ")) (active, running or newest)"))
        }
        return items
    }

    /// Numeric-aware comparison: 2.1.9 < 2.1.10.
    static func compareVersions(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedAscending
    }

    /// `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>`: every update leaves the previous
    /// checkout behind. Only paths listed in `installed_plugins.json` are in use.
    static func claudePlugins(_ ctx: ScanContext) -> [CleanItem] {
        let root = ctx.path("~/.claude/plugins")
        let cache = root + "/cache"
        guard FS.isDirectory(cache) else { return [] }
        let inUse = Set(ClaudePlugins.installed(AgentHome(home: ctx.home)).map(\.installPath))
        guard !inUse.isEmpty else { return [] }
        var old: [String] = []
        for market in FS.children(cache) where FS.isDirectory(market) {
            let name = (market as NSString).lastPathComponent
            if name.hasPrefix("temp_git_") {
                if (FS.mtime(market) ?? ctx.now) < ctx.activeAfter { old.append(market) }
                continue
            }
            for plugin in FS.children(market) where FS.isDirectory(plugin) {
                let versions = FS.children(plugin).filter(FS.isDirectory)
                // Only prune plugins we can see at least one live version of; unknown layouts are left alone.
                guard versions.contains(where: { inUse.contains($0) }) else { continue }
                // A Claude Code process keeps running the version that was current when it started.
                var keep = inUse
                let dated = versions.compactMap { v in FS.mtime(v).map { (v, $0) } }
                for start in ctx.liveClaudeStarts {
                    if let v = dated.filter({ $0.1 <= start }).max(by: { $0.1 < $1.1 }) { keep.insert(v.0) }
                }
                old += versions.filter { !keep.contains($0) && (FS.mtime($0) ?? ctx.now) < ctx.activeAfter }
            }
        }
        guard !old.isEmpty else { return [] }
        let s = FS.size(old)
        return [CleanItem(id: "claude-plugin-old-versions", category: .aiCaches,
                          title: "Claude Code plugins: old versions · \(old.count)",
                          detail: "checkouts not referenced by installed_plugins.json", safety: .safe,
                          bytes: s.bytes, files: s.files, paths: old)]
    }

    /// Claude Code scratchpads in `/private/tmp/claude-<uid>/<project>/<session>/`. Kept while the
    /// session runs; removed once it has been idle for a day.
    static func claudeScratch(_ ctx: ScanContext) -> [CleanItem] {
        let root = "/private/tmp/claude-\(getuid())"
        guard FS.isDirectory(root) else { return [] }
        let dayAgo = ctx.now.addingTimeInterval(-86400)
        var old: [String] = []
        var newest: Date?
        for project in FS.children(root) where FS.isDirectory(project) {
            for session in FS.children(project) where FS.isDirectory(session) {
                let sid = (session as NSString).lastPathComponent
                guard !ctx.liveClaudeSessions.contains(sid) else { continue }
                let s = FS.size(session, trackNewest: true)
                if (s.newest ?? ctx.now) < dayAgo {
                    old.append(session)
                    if let n = s.newest, n > (newest ?? .distantPast) { newest = n }
                }
            }
        }
        guard !old.isEmpty else { return [] }
        let s = FS.size(old)
        return [CleanItem(id: "claude-scratchpads", category: .aiCaches, title: "Claude Code scratchpads · \(old.count) sessions",
                          detail: root, safety: .safe, bytes: s.bytes, files: s.files, lastUsed: newest, paths: old,
                          note: "temporary files of finished sessions; idle for over a day")]
    }

    /// `~/.cache/codex-runtimes/*`: interrupted downloads (`tmp*`, `*.incomplete`) are dead weight.
    static func codexRuntimes(_ ctx: ScanContext) -> [CleanItem] {
        let root = ctx.path("~/.cache/codex-runtimes")
        let partial = FS.children(root).filter {
            let n = ($0 as NSString).lastPathComponent
            return (n.hasPrefix("tmp") || n.hasSuffix(".incomplete")) && (FS.mtime($0) ?? ctx.now) < ctx.activeAfter
        }
        guard !partial.isEmpty else { return [] }
        let s = FS.size(partial)
        return [CleanItem(id: "codex-runtime-partials", category: .aiCaches, title: "Codex runtimes: interrupted downloads",
                          detail: FS.tilde(root, home: ctx.home), safety: .safe, bytes: s.bytes, files: s.files, paths: partial)]
    }
}
