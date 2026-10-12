import AgentCore
import Foundation

/// Finds everything that can be cleaned. Read-only: scanning never changes the disk.
public final class DiskScanner: @unchecked Sendable {
    public var options: ScanOptions
    /// Called from background threads with a short description of the step that finished.
    public var onProgress: ((String) -> Void)?
    /// Called from background threads with each step's findings as soon as it finishes.
    public var onItems: (([CleanItem]) -> Void)?

    /// Stops the scan at the next check; what was found so far is returned.
    public let cancellation = ScanCancellation()

    /// Keep the finished report for `thermo clean run` (off in tests).
    public var saveReport = true

    public init(options: ScanOptions = ScanOptions()) { self.options = options }

    public func cancel() { cancellation.cancel() }

    /// Whether a scan step can produce the item `id`. Unknown steps answer yes, so narrowing
    /// never hides an item; it only skips steps that are known to make other ids.
    static func step(_ name: String, ruleIDs: Set<String>, mayProduce id: String) -> Bool {
        // A selector can also name a group by prefix (`codex-sessions` selects `codex-sessions/…`).
        let has = { (prefixes: [String]) in prefixes.contains { id.hasPrefix($0) || $0 == id + "/" } }
        switch name {
        case "projects": return has(["project/", "worktree/", "aider/"])
        case "AI sessions":
            return has(["claude-sessions/", "codex-sessions/", "gemini-sessions/"]) || id.contains("-tasks")
                || ["claude-orphans", "claude-project-backups", "opencode-db", "opencode-logs"].contains(id) || id.hasSuffix("-orphan-workspaces")
        case "AI tools": return ["claude-plugin-old-versions", "claude-scratchpads", "codex-runtime-partials"].contains(id)
        case "other caches": return id == "other-app-caches"
        case "docker": return id == "docker-hint"
        case "simulators": return id.hasPrefix("simulator")
        case "app data": return has(["app-data/"])
        case "tools": return ["homebrew-old-versions", "go-mod-cache", "pnpm-store-prune"].contains(id) || id.hasPrefix("editor-obsolete-extensions-")
        case "electron apps": return id == "electron-app-caches"
        case "code-sign clones": return id == "code-sign-clones"
        case "browser updates": return has([ToolCleanup.oldVersionPrefix])
        case "AI models": return !ruleIDs.contains(id) && !has(["project/", "worktree/", "aider/", "app-data/"]) && !id.hasPrefix("simulator")
        default:
            // Path rules: one step per rule, titled by the rule.
            let rules = Rules.paths.filter { $0.title == name }
            return rules.isEmpty || rules.contains { $0.id == id }
        }
    }

    public func scan() -> ScanReport {
        let started = Date()
        let language = L10n.current.rawValue
        ScanCancellation.current = cancellation
        defer { ScanCancellation.current = nil }
        // Stopped before it began: skip even the setup (reading every process is slow on a busy Mac).
        if cancellation.isCancelled {
            return ScanReport(items: [], denied: [], started: started, duration: 0, cancelled: true)
        }
        let timing = ProcessInfo.processInfo.environment["THERMO_CLEAN_TIMING"] != nil
        if timing { FileHandle.standardError.write(Data("scan: reading processes\n".utf8)) }
        let processes = ProcessTable.current(.init(cpu: false))
        if timing { FileHandle.standardError.write(Data(String(format: "scan: processes %.2fs\n", Date().timeIntervalSince(started)).utf8)) }
        let live = ClaudeSessions.live(AgentHome(home: options.home))
        let ctx = ScanContext(options: options, now: started, processes: processes,
                              agentDirs: processes.agentDirectories(),
                              liveClaudeSessions: Set(live.map(\.sessionId)),
                              liveClaudeStarts: live.compactMap(\.startedAt))
        let lock = NSLock()
        var items: [CleanItem] = []
        var denied: [String] = []

        var jobs: [(String, Set<CleanCategory>, () -> [CleanItem])] = [
            ("projects", [.projects, .agentWorktrees, .aiCaches], { Projects.scan(ctx, onItem: { self.onItems?([$0]) }) }),
            ("AI sessions", [.aiSessions], { AISessions.scan(ctx) }),
            ("AI tools", [.aiCaches], { AITools.scan(ctx) }),
            ("AI models", [.aiModels], { AIModels.scan(ctx) }),
            ("other caches", [.system], { [self.otherCaches(ctx)].compactMap { $0 } }),
            ("docker", [.devCaches], { [self.docker(ctx)].compactMap { $0 } }),
            ("simulators", [.xcode], { Simulators.scan(ctx) }),
            ("app data", [.system], { AppData.scan(ctx) }),
            ("tools", [.devCaches], { ToolCleanup.scan(ctx) }),
            ("electron apps", [.system], { [ToolCleanup.electronCaches(ctx)].compactMap { $0 } }),
            ("code-sign clones", [.system], { [ToolCleanup.codeSignClones(ctx)].compactMap { $0 } }),
            ("browser updates", [.browsers], { ToolCleanup.browserOldVersions(ctx) }),
        ]
        for rule in Rules.paths where !rule.paths.isEmpty {
            jobs.append((rule.title, [rule.category], { [self.evaluate(rule, ctx: ctx, denied: { p in lock.lock(); denied.append(p); lock.unlock() })].compactMap { $0 } }))
        }
        jobs = jobs.filter { !$0.1.isDisjoint(with: options.categories) }
        if let ids = options.onlyIDs {
            let ruleIDs = Set(Rules.paths.map(\.id))
            jobs = jobs.filter { job in ids.contains { Self.step(job.0, ruleIDs: ruleIDs, mayProduce: $0) } }
        }

        func runJob(_ i: Int) {
            guard !cancellation.isCancelled else { return }
            let t0 = Date()
            let found = jobs[i].2().filter { options.categories.contains($0.category) }
            guard !cancellation.isCancelled || jobs[i].0 == "projects" else { return }
            if timing { FileHandle.standardError.write(String(format: "%6.2fs %@\n", Date().timeIntervalSince(t0), jobs[i].0).data(using: .utf8)!) }
            lock.lock()
            items += found
            lock.unlock()
            if !found.isEmpty && jobs[i].0 != "projects" { onItems?(found) }
            onProgress?(jobs[i].0)
        }
        // At most half the cores, at utility priority, so a scan never takes the Mac over
        // (concurrentPerform used every core).
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        queue.qualityOfService = options.lowPriority ? .background : .utility
        for i in jobs.indices { queue.addOperation { runJob(i) } }
        queue.waitUntilAllOperationsAreFinished()

        for i in items.indices where !items[i].paths.isEmpty {
            var ids: [String: String] = [:]
            for p in items[i].paths { ids[p] = FileIdentity.of(p) }
            items[i].identities = ids
        }
        let order = Dictionary(uniqueKeysWithValues: CleanCategory.allCases.enumerated().map { ($1, $0) })
        items.sort { (order[$0.category]!, -$0.bytes, $0.id) < (order[$1.category]!, -$1.bytes, $1.id) }
        var report = ScanReport(items: items, denied: Array(Set(denied)).sorted(), started: started,
                                duration: Date().timeIntervalSince(started), claudeCleanupDays: claudeCleanupDays(),
                                cancelled: cancellation.isCancelled)
        report.categories = CleanCategory.allCases.filter { options.categories.contains($0) }
        report.olderThanDays = options.olderThanDays
        report.projectRoots = Array(Set(options.projectRoots)).sorted()
        report.discoverProjectRoots = options.discoverProjectRoots
        report.language = language
        // A scan narrowed to some ids is not a full report; a later run must not reuse it.
        if saveReport && options.onlyIDs == nil { ScanReportCache.save(report, home: options.home) }
        return report
    }

    /// A rule path with `*` expanded to the folders it matches.
    static func expand(_ raw: String, ctx: ScanContext) -> [String] {
        let p = ctx.path(raw)
        guard p.contains("*") else { return [p] }
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(p, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
    }

    private let claimsLock = NSLock()
    private var claimsCache: (home: String, claims: [(path: String, rule: String)])?

    /// Every location a rule names, with the rule that names it: a folder another rule covers
    /// (`~/Library/Logs/JetBrains` inside the app logs rule) is counted and removed by that rule only.
    func claims(_ ctx: ScanContext) -> [(path: String, rule: String)] {
        claimsLock.lock(); defer { claimsLock.unlock() }
        if let c = claimsCache, c.home == ctx.home { return c.claims }
        let claims = Rules.paths.flatMap { rule in rule.paths.flatMap { Self.expand($0, ctx: ctx) }.map { (path: $0, rule: rule.id) } }
        claimsCache = (ctx.home, claims)
        return claims
    }

    func evaluate(_ rule: PathRule, ctx: ScanContext, denied: (String) -> Void) -> CleanItem? {
        let roots = rule.paths.flatMap { Self.expand($0, ctx: ctx) }.filter(FS.exists)
        guard !roots.isEmpty else { return nil }
        let others = claims(ctx).filter { $0.rule != rule.id }.map(\.path)
        func claimedElsewhere(_ p: String) -> Bool { others.contains { $0 == p || $0.hasPrefix(p + "/") } }
        var paths: [String] = []
        var size = TreeSize()
        func matches(_ p: String) -> Bool {
            guard let pats = rule.match else { return true }
            let n = (p as NSString).lastPathComponent
            return pats.contains { fnmatch($0, n, FNM_CASEFOLD) == 0 }
        }
        for root in roots {
            guard ScanCancellation.current?.isCancelled != true else { return nil }
            switch rule.scope {
            case .whole:
                let s = FS.size(root, trackNewest: true)
                if s.denied { denied(root) }
                paths.append(root); size = size + s
            case .contents, .staleContents:
                if rule.scope == .contents, !FS.isDirectory(root) { continue }
                if (try? FileManager.default.contentsOfDirectory(atPath: root)) == nil { denied(root); continue }
                var found: [(path: String, size: TreeSize)] = []
                for c in FS.children(root) where matches(c) && (c as NSString).lastPathComponent != ".DS_Store" && !claimedElsewhere(c) {
                    guard ScanCancellation.current?.isCancelled != true else { return nil }
                    let s = FS.size(c, trackNewest: true)
                    if s.denied, rule.scope == .contents { denied(c) }
                    found.append((c, s))
                }
                if rule.keepNewest > 0 {
                    found.sort { ($0.size.newest ?? .distantPast) > ($1.size.newest ?? .distantPast) }
                    found.removeFirst(min(rule.keepNewest, found.count))
                }
                for (c, s) in found {
                    if rule.scope == .staleContents, (s.newest ?? ctx.now) >= ctx.staleBefore { continue }
                    paths.append(c); size = size + s
                }
            }
        }
        guard size.bytes > 0, ScanCancellation.current?.isCancelled != true else { return nil }
        let detail = roots.count == 1 ? ctx.tilde(roots[0]) : "\(ctx.tilde(roots[0])) and \(roots.count - 1) more"
        var note = rule.note.map { tr($0) }
        if rule.scope == .staleContents {
            note = [note, tr("only items untouched for %1$@ days", String(ctx.options.olderThanDays))].compactMap { $0 }.joined(separator: tr("; "))
        }
        if rule.keepNewest > 0 {
            note = [note, tr("the %1$@ most recently used are kept", String(rule.keepNewest))].compactMap { $0 }.joined(separator: tr("; "))
        }
        return CleanItem(id: rule.id, category: rule.category, title: tr(rule.title), detail: detail, safety: rule.safety,
                         bytes: size.bytes, files: size.files, lastUsed: size.newest, paths: paths, note: note,
                         blocked: ctx.processes.running(rule.apps).map { tr("quit %1$@ first", $0) })
    }

    /// `~/Library/Caches` folders no specific rule covers.
    func otherCaches(_ ctx: ScanContext) -> CleanItem? {
        let root = ctx.path(Rules.otherCachesRoot)
        let claimed = Set(Rules.paths.flatMap(\.paths).map(ctx.path))
        let skipPrefixes = ["com.apple.", "CloudKit", "dev.thermo", "familycircled", "FamilyCircle", "GameKit", "Metadata",
                            "PassKit", "storeassetd", "SiriTTS", "TemporaryItems"]
        var paths: [String] = []
        var size = TreeSize()
        for c in FS.children(root) {
            guard ScanCancellation.current?.isCancelled != true else { return nil }
            let n = (c as NSString).lastPathComponent
            guard !claimed.contains(c), !claimed.contains(where: { $0.hasPrefix(c + "/") }),
                  !skipPrefixes.contains(where: { n.hasPrefix($0) }), n != ".DS_Store" else { continue }
            let s = FS.size(c, trackNewest: true)
            // Caches written in the last hour belong to something running right now.
            guard s.bytes > 0, !s.denied, (s.newest ?? ctx.now) < ctx.now.addingTimeInterval(-3600) else { continue }
            paths.append(c); size = size + s
        }
        guard size.bytes > 0 else { return nil }
        return CleanItem(id: "other-app-caches", category: .system, title: tr("Other app caches"),
                         detail: trCount(paths.count, "%1$@ folder in ~/Library/Caches", "%1$@ folders in ~/Library/Caches"), safety: .safe, bytes: size.bytes,
                         files: size.files, lastUsed: size.newest, paths: paths,
                         note: tr("apps rebuild their caches; ones used in the last hour are skipped"))
    }

    func docker(_ ctx: ScanContext) -> CleanItem? {
        let candidates = ["~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
                          "~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.qcow2",
                          "~/.orbstack/data/data.img", "~/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/data.img",
                          "~/.colima/_lima/colima/diffdisk"].map(ctx.path)
        guard let disk = candidates.first(where: FS.exists) else { return nil }
        let s = FS.size(disk)
        guard s.bytes > 0 else { return nil }
        let orb = disk.contains("orbstack"), colima = disk.contains("colima")
        return CleanItem(id: "docker-hint", category: .devCaches,
                         title: tr(orb ? "OrbStack disk image" : colima ? "Colima disk image" : "Docker disk image"),
                         detail: ctx.tilde(disk), safety: .review, bytes: s.bytes, files: 1,
                         note: tr("unused images, containers and build cache live inside this file"),
                         hint: "docker system prune -a  (then docker builder prune)")
    }

    /// Claude Code's own retention (`cleanupPeriodDays` in ~/.claude/settings.json, default 30).
    func claudeCleanupDays() -> Int? {
        let settings = FS.expand("~/.claude/settings.json", home: options.home)
        guard FS.exists(FS.expand("~/.claude/projects", home: options.home)) else { return nil }
        guard let data = FileManager.default.contents(atPath: settings),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 30 }
        return (obj["cleanupPeriodDays"] as? Int) ?? 30
    }
}

// MARK: - Selection

public extension ScanReport {
    /// Resolves CLI/app selectors: an item id, an id prefix (`claude-sessions` matches
    /// `claude-sessions/…`), a category (`ai-sessions`), `ai` (all AI categories), `safe` (every safe item)
    /// or `all` (everything except risky). Exact ids may select risky items.
    func select(_ selectors: [String]) -> [CleanItem] {
        var out: [CleanItem] = []
        var seen = Set<String>()
        func add(_ i: CleanItem) { if seen.insert(i.id).inserted { out.append(i) } }
        for sel in selectors {
            // `ITEM#PART[,PART…]`: just those sessions of one item.
            if let hash = sel.firstIndex(of: "#") {
                let id = String(sel[..<hash]).lowercased()
                let wanted = Set(sel[sel.index(after: hash)...].split(separator: ",").map(String.init))
                if let i = items.first(where: { $0.id.lowercased() == id }), seen.insert(i.id).inserted {
                    let narrowed = i.only(wanted)
                    if !(narrowed.parts ?? []).isEmpty { out.append(narrowed) }
                }
                continue
            }
            let s = sel.lowercased()
            for i in items {
                let exact = i.id.lowercased() == s
                let byPrefix = i.id.lowercased().hasPrefix(s + "/") || (s.hasSuffix("*") && i.id.lowercased().hasPrefix(String(s.dropLast())))
                let byGroup = s == i.category.rawValue || (s == "ai" && i.category.isAI) || s == "all" || (s == "safe" && i.safety == .safe)
                if exact || ((byPrefix || byGroup) && i.safety != .risky) { add(i) }
            }
        }
        return out
    }
}
