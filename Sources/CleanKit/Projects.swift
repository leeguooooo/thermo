import Foundation
import AgentCore

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
        Kind(name: "Swift", markers: ["Package.swift"], artifacts: [".build", ".swiftpm", "dist", "build"]),
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
        // motion-use / drama-use films: `out` holds the rendered video.
        Kind(name: "Film", markers: ["film.json"], artifacts: ["out"]),
    ]

    /// Output folders checked for proof that they are a build cache, whatever the project kind
    /// (an Xcode project has no marker file we know; a root `.build` may serve an app below it).
    static let evidentNames = [".build", "build", "DerivedData", "target", "out", "dist"]

    /// A cache by its own declaration (CACHEDIR.TAG: Cargo, SwiftPM, …) or Xcode derived data.
    static func isEvidentCache(_ p: String) -> Bool {
        BuildCacheEvidence.capture(p) != nil
    }

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
        /// `evident`: proved a cache by its contents, so even a generic name is rebuilt exactly.
        case artifact(project: String, kind: String, name: String, activity: Date?, source: String?, evident: Bool = false)
        case worktree(path: String, repo: String)
        case aider(project: String, paths: [String])
    }

    static func scan(_ ctx: ScanContext, onItem: ((CleanItem) -> Void)? = nil) -> [CleanItem] {
        var found: [Candidate] = []
        var visited = Set<String>()
        var ctx = ctx
        let timing = ProcessInfo.processInfo.environment["THERMO_CLEAN_TIMING"] != nil
        let began = Date()
        if timing { FileHandle.standardError.write(Data("projects: collecting activity\n".utf8)) }
        ctx.signals = ProjectSignals.collect(home: ctx.home)
        if timing { FileHandle.standardError.write(Data(String(format: "projects: activity %.2fs\n", Date().timeIntervalSince(began)).utf8)) }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = ctx.options.lowPriority ? .background : .utility
        let lock = NSLock()
        var items: [CleanItem] = []
        let cancellation = ScanCancellation.current
        // Start measuring as projects are discovered; large roots must not delay every result.
        // A worktree is reached both from its repository and, when an agent worked in it, as a
        // project root of its own: offer it once.
        var worktrees = Set<String>()
        func enqueue(_ candidate: Candidate) {
            if case let .worktree(path, _) = candidate, !worktrees.insert(path).inserted { return }
            queue.addOperation {
                ScanCancellation.withCurrent(cancellation) {
                    guard ScanCancellation.current?.isCancelled != true else { return }
                    guard let item = make(candidate, ctx: ctx), ScanCancellation.current?.isCancelled != true else { return }
                    lock.lock(); items.append(item); lock.unlock()
                    onItem?(item)
                }
            }
        }
        let roots = ctx.options.projectRoots + (ctx.options.discoverProjectRoots ? ctx.signals.roots(home: ctx.home) : [])
        for root in roots where root != ctx.home {
            walk(root, depth: 0, ctx: ctx, visited: &visited, into: &found, onCandidate: enqueue)
            if timing { FileHandle.standardError.write(Data(String(format: "projects: root done %.2fs, %d candidates %@\n", Date().timeIntervalSince(began), found.count, root).utf8)) }
        }
        if timing {
            FileHandle.standardError.write(Data("walk: \(visited.count) dirs, \(found.count) candidates, \(String(format: "%.2f", Date().timeIntervalSince(ctx.now)))s\n".utf8))
        }
        if ctx.options.categories.contains(.projects) {
            for root in FS.children(ctx.path("~/.cache")) where FS.isDirectory(root) {
                let name = (root as NSString).lastPathComponent.lowercased()
                let target = name == "target" || name.hasSuffix("-target") || name.hasSuffix("_target")
                if target, FS.exists(root + "/.rustc_info.json") || FS.isDirectory(root + "/debug") || FS.isDirectory(root + "/release") {
                    enqueue(.artifact(project: (root as NSString).deletingLastPathComponent, kind: "Rust cache", name: (root as NSString).lastPathComponent,
                                      activity: FS.mtime(root), source: nil))
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return items
    }

    static func id(_ path: String, ctx: ScanContext) -> String {
        let t = FS.tilde(path, home: ctx.home)
        return AISessions.slug(t.hasPrefix("~/") ? String(t.dropFirst(2)) : t)
    }

    static func make(_ c: Candidate, ctx: ScanContext) -> CleanItem? {
        switch c {
        case let .artifact(dir, kind, a, activity, source, evident):
            let p = dir + "/" + a
            let s = ctx.options.exactSizes ? FS.size(p) : FS.discoverySize(p)
            guard s.bytes > 1_000_000 else { return nil }
            let evidence = evident ? BuildCacheEvidence.capture(p) : nil
            let stale = activity.map { $0 < ctx.staleBefore } ?? true
            var note = activity.map { d in
                source.map { tr("last used %1$@ (%2$@)", AgeFormat.string(d, now: ctx.now), $0) } ?? tr("last changed %1$@", AgeFormat.string(d, now: ctx.now))
            }
            if !stale { note = [note, tr("in use; it will have to rebuild")].compactMap { $0 }.joined(separator: tr("; ")) }
            let agentRunning = ctx.agentDirs.contains {
                $0 == dir || $0.hasPrefix(dir + "/") ||
                    (dir.hasPrefix($0 + "/") && ProjectSignals.isRepoRoot($0, containing: dir))
            }
            let blocked: String?
            if evident && evidence == nil { blocked = tr("Build cache evidence changed; scan and review again.") }
            else if agentRunning { blocked = tr("an agent is running in it") }
            else { blocked = nil }
            var item = CleanItem(
                id: "project/" + id(p, ctx: ctx), category: .projects,
                title: "\((dir as NSString).lastPathComponent) · \(a)",
                detail: FS.tilde(dir, home: ctx.home) + " · \(kind)",
                // Generic output folders can hold things worth keeping (a rendered video in `out`, a
                // release binary in `dist`): never in the one-click safe set, always to the Trash.
                safety: stale && (evidence != nil || !generic.contains(a)) ? .safe : .review,
                bytes: s.bytes, files: s.files, lastUsed: activity, paths: [p], note: note, blocked: blocked, group: dir)
            item.regenerable = evidence != nil || !generic.contains(a)
            item.buildCacheEvidence = evidence.map { [p: $0] }
            item.estimatedSize = !ctx.options.exactSizes; item.sizeIncomplete = s.incomplete
            return item
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

    static func walk(_ dir: String, depth: Int, ctx: ScanContext, visited: inout Set<String>, into out: inout [Candidate], onCandidate: ((Candidate) -> Void)? = nil) {
        guard ScanCancellation.current?.isCancelled != true, depth <= maxDepth, visited.insert(dir).inserted else { return }
        guard let entries = FS.entries(dir) else { return }
        let names = entries.map(\.name)
        let set = Set(names)
        var claimed = Set<String>()

        let matches = ctx.options.categories.contains(.projects) ? kinds.filter { k in
            k.markers.contains { m in
                m.hasSuffix("*") ? names.contains { $0.hasSuffix(String(m.dropLast())) } : (m.contains("/") ? FS.exists(dir + "/" + m) : set.contains(m))
            }
        } : []
        // Most packages have no installed dependencies or build output. Do not load their
        // Git index or activity history just to discover there is nothing to measure.
        let existingArtifacts = Set(matches.flatMap(\.artifacts).filter { FS.isDirectory(dir + "/" + $0) })
        // Caches that prove themselves; inside a mixed output folder (a `build` holding a DMG next
        // to its DerivedData) only the proven parts, so finished products stay.
        var evident: [String] = []
        if ctx.options.categories.contains(.projects) {
            for n in evidentNames where set.contains(n) && FS.isDirectory(dir + "/" + n) {
                if isEvidentCache(dir + "/" + n) { evident.append(n); continue }
                for suffix in ["ModuleCache.noindex", "CompilationCache.noindex", "Build/Intermediates.noindex"] {
                    let part = n + "/" + suffix
                    if isEvidentCache(dir + "/" + part) { evident.append(part) }
                }
                for c in FS.entries(dir + "/" + n) ?? [] where c.isDir && isEvidentCache(dir + "/" + n + "/" + c.name) {
                    let part = n + "/" + c.name
                    if !evident.contains(part) { evident.append(part) }
                }
            }
        }
        if !existingArtifacts.isEmpty || !evident.isEmpty {
            // Last use: the latest of agent/editor sessions in it, git activity and its own files.
            var activity = projectActivity(dir, names: names, ignoring: Set(matches.flatMap(\.artifacts)))
            var source: String?
            if let use = ctx.signals.lastUse(of: dir), use.date > (activity ?? .distantPast) { activity = use.date; source = use.source }
            if let git = ProjectSignals.gitActivity(dir), git > (activity ?? .distantPast) { activity = git; source = "git" }
            let protected = protectedArtifacts(dir, Array(existingArtifacts) + evident)
            for a in evident where !protected.contains(a) {
                // The folder it sits in is settled either way: never offered whole as well.
                claimed.insert(String(a.split(separator: "/").first ?? Substring(a)))
                let candidate = Candidate.artifact(project: dir, kind: "Build cache", name: a, activity: activity, source: source, evident: true)
                out.append(candidate)
                onCandidate?(candidate)
            }
            for k in matches {
                for a in k.artifacts where existingArtifacts.contains(a) && !claimed.contains(a) {
                    let p = dir + "/" + a
                    guard FS.isDirectory(p) else { continue }
                    // `build`/`bin`/`obj` are only build output when they are not tracked source folders.
                    if protected.contains(a) { continue }
                    claimed.insert(a)
                    let candidate = Candidate.artifact(project: dir, kind: k.name, name: a, activity: activity, source: source)
                    out.append(candidate)
                    onCandidate?(candidate)
                }
            }
        }
        let leftovers = agentLeftovers(dir, names: set).filter { candidate in
            switch candidate {
            case .worktree: return ctx.options.categories.contains(.agentWorktrees)
            case .aider: return ctx.options.categories.contains(.aiCaches)
            case .artifact: return false
            }
        }

        out += leftovers
        for candidate in leftovers { onCandidate?(candidate) }
        // A linked worktree outside its repository (`git worktree add ../x`, an agent's scratch
        // checkout under ~/.codex): offered whole like the ones inside it. Its build output is
        // still offered on its own, since a worktree holding ignored files is never removed.
        if ctx.options.categories.contains(.agentWorktrees), set.contains(".git"), let repo = linkedWorktreeRepository(dir) {
            let candidate = Candidate.worktree(path: dir, repo: repo)
            out.append(candidate)
            onCandidate?(candidate)
        }

        for (n, isDir) in entries where isDir && !n.hasPrefix(".") && !skip.contains(n) && !claimed.contains(n) {
            if [".app", ".xcodeproj", ".xcworkspace", ".framework", ".photoslibrary", ".musiclibrary", ".fcpbundle",
                ".imovielibrary", ".tvlibrary", ".logicx", ".band"].contains(where: { n.hasSuffix($0) }) { continue }
            walk(dir + "/" + n, depth: depth + 1, ctx: ctx, visited: &visited, into: &out, onCandidate: onCandidate)
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

    /// One Git query per project, including nested packages and worktrees. On failure we
    /// conservatively protect every candidate instead of treating unknown files as disposable.
    static func protectedArtifacts(_ dir: String, _ names: [String]) -> Set<String> {
        var ancestor = dir
        var inRepository = false
        while ancestor != "/" {
            if FS.exists(ancestor + "/.git") { inRepository = true; break }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
        guard inRepository else { return [] }
        let result = CommandRunner.run("/usr/bin/git", arguments: ["-C", dir, "ls-files", "-z", "--"] + names,
                                       timeout: 5, outputLimit: 1_048_576, captureError: false,
                                       cancelled: { ScanCancellation.current?.isCancelled == true })
        guard result.status == 0, !result.timedOut, !result.cancelled, !result.truncated else { return Set(names) }
        let tracked = result.output.split(separator: "\0").map(String.init)
        return Set(names.filter { name in tracked.contains { $0 == name || $0.hasPrefix(name + "/") } })
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

    /// The main checkout a linked worktree belongs to, from its `.git` file
    /// (`gitdir: <repo>/.git/worktrees/<name>`); nil for anything else.
    static func linkedWorktreeRepository(_ dir: String) -> String? {
        var st = stat()
        guard lstat(dir + "/.git", &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size < 4096,
              let text = try? String(contentsOfFile: dir + "/.git", encoding: .utf8), text.hasPrefix("gitdir: ") else { return nil }
        let gitdir = text.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = gitdir.range(of: "/.git/worktrees/", options: .backwards) else { return nil }
        let repo = String(gitdir[..<r.lowerBound])
        return FS.isDirectory(repo + "/.git") ? repo : nil
    }

    /// A worktree an agent created. Removed only through git, and only when it has nothing unsaved.
    static func worktreeItem(_ wt: String, repo: String, repoName: String, ctx: ScanContext) -> CleanItem? {
        let s = ctx.options.exactSizes ? FS.size(wt, trackNewest: true) : FS.discoverySize(wt)
        let gitFile = wt + "/.git"
        let registered = FS.exists(gitFile)
        // Outside its repository the folder name alone is often generic (`source`, `worktree`).
        let inside = wt.hasPrefix(repo + "/")
        let name = inside ? (wt as NSString).lastPathComponent
            : ((wt as NSString).deletingLastPathComponent as NSString).lastPathComponent + "/" + (wt as NSString).lastPathComponent
        var safety = Safety.review
        var note: String?
        var blocked: String?
        var detail = FS.tilde(wt, home: ctx.home)
        if !registered {
            safety = .review
            note = tr("not a git worktree any more (left behind)")
            do { try WorktreeCleanup.verifyActivity(path: wt, metadata: nil, now: ctx.now) }
            catch { blocked = tr(String(describing: error)) }
        } else {
            let branch = (try? WorktreeCleanup.git(wt, ["rev-parse", "--abbrev-ref", "HEAD"])) ?? "?"
            detail += " · " + (branch == "HEAD" ? tr("detached HEAD") : tr("branch %1$@", branch))
            do {
                guard try WorktreeCleanup.registration(wt, processes: ctx.processes, now: ctx.now) != nil else {
                    throw WorktreeCleanup.Refusal("Git worktree registration is unavailable; keep this folder")
                }
                note = branch == "HEAD" ? tr("clean, detached checkout") : tr("clean; branch %1$@ stays in the repository", branch)
            } catch { blocked = tr(String(describing: error)) }
        }
        if let why = WorktreeCleanup.ownerRefusal(wt) { blocked = tr(why) }
        if !ctx.processes.available { blocked = tr("could not verify processes using this worktree; keep it") }
        if ctx.agentDirs.contains(where: { $0 == wt || $0.hasPrefix(wt + "/") }) { blocked = tr("an agent is running in it") }
        guard s.bytes > 0 else { return nil }
        var item = CleanItem(id: "worktree/" + AISessions.slug(repoName) + "/" + (inside ? AISessions.slug(name) : id(wt, ctx: ctx)), category: .agentWorktrees,
                         title: tr("Agent worktree") + " · \(repoName)/\(name)", detail: detail, safety: safety,
                         bytes: s.bytes, files: s.files, lastUsed: s.newest, paths: [wt], note: note, blocked: blocked,
                         group: repo)
        item.estimatedSize = !ctx.options.exactSizes; item.sizeIncomplete = s.incomplete
        return item
    }
}
