import Foundation

/// Build output inside project folders (the kondo / npkill idea), plus what AI agents leave in
/// repositories: worktrees and Aider caches.
enum Projects {
    struct Kind {
        let name: String
        /// Any of these in a folder marks it as a project of this kind (`*` suffix = extension match).
        let markers: [String]
        let artifacts: [String]
    }

    static let kinds: [Kind] = [
        Kind(name: "Node", markers: ["package.json"],
             artifacts: ["node_modules", ".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit", ".angular", ".expo",
                         ".vercel/output", ".output", ".wrangler", "dist", "build", "out", "coverage", "storybook-static",
                         ".docusaurus", ".vite", ".cache"]),
        Kind(name: "Rust", markers: ["Cargo.toml"], artifacts: ["target"]),
        Kind(name: "Swift", markers: ["Package.swift"], artifacts: [".build", ".swiftpm"]),
        Kind(name: "CocoaPods", markers: ["Podfile"], artifacts: ["Pods"]),
        Kind(name: "Python", markers: ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "uv.lock"],
             artifacts: [".venv", "venv", ".tox", ".nox", ".mypy_cache", ".pytest_cache", ".ruff_cache", "__pycache__", "dist", "build"]),
        Kind(name: "Gradle", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
             artifacts: ["build", ".gradle"]),
        Kind(name: "Maven", markers: ["pom.xml", "build.sbt"], artifacts: ["target"]),
        Kind(name: "CMake", markers: ["CMakeLists.txt"], artifacts: ["build", "cmake-build-debug", "cmake-build-release"]),
        Kind(name: "Flutter", markers: ["pubspec.yaml"], artifacts: ["build", ".dart_tool"]),
        Kind(name: "Elixir", markers: ["mix.exs"], artifacts: ["_build", "deps", ".elixir_ls"]),
        Kind(name: ".NET", markers: [".csproj*", ".fsproj*", ".sln*"], artifacts: ["bin", "obj"]),
        Kind(name: "Zig", markers: ["build.zig"], artifacts: ["zig-cache", ".zig-cache", "zig-out"]),
        Kind(name: "Haskell", markers: ["stack.yaml"], artifacts: [".stack-work"]),
        Kind(name: "Terraform", markers: [".terraform.lock.hcl"], artifacts: [".terraform"]),
        Kind(name: "Unity", markers: ["ProjectSettings/ProjectVersion.txt"], artifacts: ["Library", "Temp", "Obj"]),
    ]

    /// Folders never descended into while looking for projects.
    static let skip: Set<String> = [".git", "node_modules", "Library", ".Trash", "Pods", ".build", "target", "vendor",
                                    "DerivedData", ".venv", "venv", ".cache", "dist", "build", "out", "coverage",
                                    "site-packages", "__pycache__", "Assets", "assets", "public", "static", "images",
                                    "fixtures", "testdata", "third_party", "external"]

    static let maxDepth = 6

    /// Output folders whose names projects also use for real files (some commit `dist`): skipped
    /// when git tracks them, and only ever offered for review.
    static let generic = ["dist", "build", "out", "coverage"]

    /// Something found by the walk; sized afterwards in parallel.
    enum Candidate {
        case artifact(project: String, kind: String, name: String, activity: Date?, source: String?)
        case worktree(path: String, repo: String)
        case aider(project: String, paths: [String])
    }

    static func scan(_ ctx: ScanContext) -> [CleanItem] {
        var found: [Candidate] = []
        var visited = Set<String>()
        var ctx = ctx
        ctx.signals = ProjectSignals.collect(home: ctx.home)
        // The usual project folders, then every folder an agent or editor worked in (projects kept
        // in odd places, like ~/test/x, only show up there). The home folder itself is never walked.
        let roots = ctx.options.projectRoots + ctx.signals.roots(home: ctx.home)
        for root in roots where root != ctx.home {
            walk(root, depth: 0, ctx: ctx, visited: &visited, into: &found)
        }
        if ProcessInfo.processInfo.environment["THERMO_CLEAN_TIMING"] != nil {
            FileHandle.standardError.write("walk: \(visited.count) dirs, \(found.count) candidates, \(String(format: "%.2f", Date().timeIntervalSince(ctx.now)))s\n".data(using: .utf8)!)
        }
        if !ctx.options.categories.contains(.projects) {
            found = found.filter { if case .artifact = $0 { return false }; return true }
        }
        var items = [CleanItem?](repeating: nil, count: found.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: found.count) { i in
            let item = make(found[i], ctx: ctx)
            lock.lock(); items[i] = item; lock.unlock()
        }
        return items.compactMap { $0 }
    }

    static func id(_ path: String, ctx: ScanContext) -> String {
        let t = FS.tilde(path, home: ctx.home)
        return AISessions.slug(t.hasPrefix("~/") ? String(t.dropFirst(2)) : t)
    }

    static func make(_ c: Candidate, ctx: ScanContext) -> CleanItem? {
        switch c {
        case let .artifact(dir, kind, a, activity, source):
            let p = dir + "/" + a
            let s = FS.size(p)
            guard s.bytes > 1_000_000 else { return nil }
            let stale = activity.map { $0 < ctx.staleBefore } ?? true
            var note = activity.map { d in
                source.map { tr("last used %1$@ (%2$@)", AgeFormat.string(d, now: ctx.now), $0) } ?? tr("last changed %1$@", AgeFormat.string(d, now: ctx.now))
            }
            if !stale { note = [note, tr("in use; it will have to rebuild")].compactMap { $0 }.joined(separator: tr("; ")) }
            return CleanItem(
                id: "project/" + id(p, ctx: ctx), category: .projects,
                title: "\((dir as NSString).lastPathComponent) · \(a)",
                detail: FS.tilde(dir, home: ctx.home) + " · \(kind)",
                // Generic output folders can hold things worth keeping (a rendered video in `out`, a
                // release binary in `dist`): never in the one-click safe set, always to the Trash.
                safety: stale && !generic.contains(a) ? .safe : .review,
                bytes: s.bytes, files: s.files, lastUsed: activity, paths: [p], note: note, group: dir)
        case let .worktree(wt, repo):
            return worktreeItem(wt, repo: repo, repoName: (repo as NSString).lastPathComponent, ctx: ctx)
        case let .aider(dir, paths):
            let s = FS.size(paths)
            guard s.bytes > 100_000 else { return nil }
            return CleanItem(id: "aider/" + id(dir, ctx: ctx), category: .aiCaches,
                             title: tr("Aider repo map cache") + " · \((dir as NSString).lastPathComponent)", detail: FS.tilde(dir, home: ctx.home),
                             safety: .safe, bytes: s.bytes, files: s.files, paths: paths)
        }
    }

    static func walk(_ dir: String, depth: Int, ctx: ScanContext, visited: inout Set<String>, into out: inout [Candidate]) {
        guard depth <= maxDepth, visited.insert(dir).inserted else { return }
        guard let entries = FS.entries(dir) else { return }
        let names = entries.map(\.name)
        let set = Set(names)
        var claimed = Set<String>()

        let matches = kinds.filter { k in
            k.markers.contains { m in
                m.hasSuffix("*") ? names.contains { $0.hasSuffix(String(m.dropLast())) } : (m.contains("/") ? FS.exists(dir + "/" + m) : set.contains(m))
            }
        }
        if !matches.isEmpty {
            // Last use: the latest of agent/editor sessions in it, git activity and its own files.
            var activity = projectActivity(dir, names: names, ignoring: Set(matches.flatMap(\.artifacts)))
            var source: String?
            if let use = ctx.signals.lastUse(of: dir), use.date > (activity ?? .distantPast) { activity = use.date; source = use.source }
            if let git = ProjectSignals.gitActivity(dir), git > (activity ?? .distantPast) { activity = git; source = "git" }
            for k in matches {
                for a in k.artifacts where !claimed.contains(a) {
                    let p = dir + "/" + a
                    guard FS.isDirectory(p) else { continue }
                    // `build`/`bin`/`obj` are only build output when they are not tracked source folders.
                    if (["bin", "obj", "Library", "deps"] + Self.generic).contains(a), gitTracks(dir, a) { continue }
                    claimed.insert(a)
                    out.append(.artifact(project: dir, kind: k.name, name: a, activity: activity, source: source))
                }
            }
        }
        out += agentLeftovers(dir, names: set)

        for (n, isDir) in entries where isDir && !n.hasPrefix(".") && !skip.contains(n) && !claimed.contains(n) {
            if n.hasSuffix(".app") || n.hasSuffix(".xcodeproj") || n.hasSuffix(".xcworkspace") || n.hasSuffix(".framework") { continue }
            walk(dir + "/" + n, depth: depth + 1, ctx: ctx, visited: &visited, into: &out)
        }
    }

    /// Newest modification of the project's own files (top two levels, artifacts excluded).
    static func projectActivity(_ dir: String, names: [String], ignoring: Set<String>) -> Date? {
        var newest: Date?
        func see(_ p: String) { if let m = FS.mtime(p), m > (newest ?? .distantPast) { newest = m } }
        for n in names where !ignoring.contains(n) && n != ".DS_Store" {
            let p = dir + "/" + n
            see(p)
            if n == "src" || n == "Sources" || n == "app" || n == "lib" {
                for c in (FS.entries(p) ?? []).prefix(60) { see(p + "/" + c.name) }
            }
        }
        if FS.isDirectory(dir + "/.git") { see(dir + "/.git/HEAD"); see(dir + "/.git/index") }
        return newest
    }

    static func gitTracks(_ dir: String, _ sub: String) -> Bool {
        guard FS.exists(dir + "/.git") else { return false }
        let out = Shell.run("git -C \(Shell.quote(dir)) ls-files -- \(Shell.quote(sub)) | head -1", timeout: 5) ?? ""
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: AI agent leftovers in repositories

    /// `.claude/worktrees/*`, `.worktrees/*` (agent worktrees) and Aider caches.
    static func agentLeftovers(_ dir: String, names: Set<String>) -> [Candidate] {
        var out: [Candidate] = []
        for wtRoot in [dir + "/.claude/worktrees", dir + "/.worktrees", dir + "/.codex/worktrees"] where FS.isDirectory(wtRoot) {
            for wt in FS.children(wtRoot) where FS.isDirectory(wt) { out.append(.worktree(path: wt, repo: dir)) }
        }
        let tagCaches = names.filter { $0.hasPrefix(".aider.tags.cache") }.map { dir + "/" + $0 }
        if !tagCaches.isEmpty { out.append(.aider(project: dir, paths: tagCaches.sorted())) }
        return out
    }

    /// A worktree an agent created. Removed only through git, and only when it has nothing unsaved.
    static func worktreeItem(_ wt: String, repo: String, repoName: String, ctx: ScanContext) -> CleanItem? {
        let s = FS.size(wt, trackNewest: true)
        let gitFile = wt + "/.git"
        let registered = FS.exists(gitFile)
        let name = (wt as NSString).lastPathComponent
        var safety = Safety.review
        var note: String?
        var blocked: String?
        var detail = FS.tilde(wt, home: ctx.home)
        if !registered {
            safety = .safe
            note = tr("not a git worktree any more (left behind)")
        } else {
            let q = Shell.quote(wt)
            let status = Shell.run("git -C \(q) status --porcelain --untracked-files=normal | head -20", timeout: 10)
            let branch = Shell.run("git -C \(q) rev-parse --abbrev-ref HEAD", timeout: 5)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
            detail += " · " + (branch == "HEAD" ? tr("detached HEAD") : tr("branch %1$@", branch))
            if status == nil {
                blocked = tr("git could not read this worktree")
            } else if !(status ?? "").isEmpty {
                safety = .risky
                note = tr("has uncommitted changes")
            } else {
                // The branch itself lives in the main repository and survives `git worktree prune`.
                note = branch == "HEAD" ? tr("clean, detached checkout") : tr("clean; branch %1$@ stays in the repository", branch)
            }
        }
        if ctx.agentDirs.contains(where: { $0 == wt || $0.hasPrefix(wt + "/") }) { blocked = tr("an agent is running in it") }
        if (s.newest ?? ctx.now) > ctx.activeAfter, blocked == nil { blocked = tr("modified in the last 2 hours") }
        guard s.bytes > 0 else { return nil }
        return CleanItem(id: "worktree/" + AISessions.slug(repoName) + "/" + AISessions.slug(name), category: .aiSessions,
                         title: tr("Agent worktree") + " · \(repoName)/\(name)", detail: detail, safety: safety,
                         bytes: s.bytes, files: s.files, lastUsed: s.newest, paths: [wt], note: note, blocked: blocked,
                         afterClean: ["git -C \(Shell.quote(repo)) worktree prune"])
    }
}
