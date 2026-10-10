import Foundation

/// Finds everything that can be cleaned. Read-only: scanning never changes the disk.
public final class DiskScanner: @unchecked Sendable {
    public var options: ScanOptions
    /// Called from background threads with a short description of the step that finished.
    public var onProgress: ((String) -> Void)?

    public init(options: ScanOptions = ScanOptions()) { self.options = options }

    public func scan() -> ScanReport {
        let started = Date()
        let processes = ProcessTable.current(.init(cpu: false))
        let live = ClaudeSessions.live(AgentHome(home: options.home))
        let ctx = ScanContext(options: options, now: started, processes: processes,
                              agentDirs: processes.agentDirectories(),
                              liveClaudeSessions: Set(live.map(\.sessionId)),
                              liveClaudeStarts: live.compactMap(\.startedAt))
        let lock = NSLock()
        var items: [CleanItem] = []
        var denied: [String] = []

        var jobs: [(String, Set<CleanCategory>, () -> [CleanItem])] = [
            ("projects", [.projects, .aiSessions, .aiCaches], { Projects.scan(ctx) }),
            ("AI sessions", [.aiSessions], { AISessions.scan(ctx) }),
            ("AI tools", [.aiCaches], { AITools.scan(ctx) }),
            ("AI models", [.aiModels], { AIModels.scan(ctx) }),
            ("other caches", [.system], { [self.otherCaches(ctx)].compactMap { $0 } }),
            ("docker", [.devCaches], { [self.docker(ctx)].compactMap { $0 } }),
        ]
        for rule in Rules.paths where !rule.paths.isEmpty {
            jobs.append((rule.title, [rule.category], { [self.evaluate(rule, ctx: ctx, denied: { p in lock.lock(); denied.append(p); lock.unlock() })].compactMap { $0 } }))
        }
        jobs = jobs.filter { !$0.1.isDisjoint(with: options.categories) }

        let timing = ProcessInfo.processInfo.environment["THERMO_CLEAN_TIMING"] != nil
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let t0 = Date()
            let found = jobs[i].2().filter { options.categories.contains($0.category) }
            if timing { FileHandle.standardError.write(String(format: "%6.2fs %@\n", Date().timeIntervalSince(t0), jobs[i].0).data(using: .utf8)!) }
            lock.lock()
            items += found
            lock.unlock()
            onProgress?(jobs[i].0)
        }

        let order = Dictionary(uniqueKeysWithValues: CleanCategory.allCases.enumerated().map { ($1, $0) })
        items.sort { (order[$0.category]!, -$0.bytes, $0.id) < (order[$1.category]!, -$1.bytes, $1.id) }
        return ScanReport(items: items, denied: Array(Set(denied)).sorted(), started: started,
                          duration: Date().timeIntervalSince(started), claudeCleanupDays: claudeCleanupDays())
    }

    func evaluate(_ rule: PathRule, ctx: ScanContext, denied: (String) -> Void) -> CleanItem? {
        let roots = rule.paths.map(ctx.path).filter(FS.exists)
        guard !roots.isEmpty else { return nil }
        var paths: [String] = []
        var size = TreeSize()
        func matches(_ p: String) -> Bool {
            guard let pats = rule.match else { return true }
            let n = (p as NSString).lastPathComponent
            return pats.contains { fnmatch($0, n, FNM_CASEFOLD) == 0 }
        }
        for root in roots {
            switch rule.scope {
            case .whole:
                let s = FS.size(root, trackNewest: true)
                if s.denied { denied(root) }
                paths.append(root); size = size + s
            case .contents:
                if !FS.isDirectory(root) { continue }
                if (try? FileManager.default.contentsOfDirectory(atPath: root)) == nil { denied(root); continue }
                for c in FS.children(root) where matches(c) && (c as NSString).lastPathComponent != ".DS_Store" {
                    let s = FS.size(c, trackNewest: true)
                    if s.denied { denied(c) }
                    paths.append(c); size = size + s
                }
            case .staleContents:
                if (try? FileManager.default.contentsOfDirectory(atPath: root)) == nil { denied(root); continue }
                for c in FS.children(root) where matches(c) && (c as NSString).lastPathComponent != ".DS_Store" {
                    let s = FS.size(c, trackNewest: true)
                    guard (s.newest ?? ctx.now) < ctx.staleBefore else { continue }
                    paths.append(c); size = size + s
                }
            }
        }
        guard size.bytes > 0 else { return nil }
        let detail = roots.count == 1 ? ctx.tilde(roots[0]) : "\(ctx.tilde(roots[0])) and \(roots.count - 1) more"
        var note = rule.note.map { tr($0) }
        if rule.scope == .staleContents {
            note = [note, tr("only items untouched for %1$@ days", String(ctx.options.olderThanDays))].compactMap { $0 }.joined(separator: "; ")
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
                          "~/.orbstack/data/data.img", "~/.colima/_lima/colima/diffdisk"].map(ctx.path)
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
