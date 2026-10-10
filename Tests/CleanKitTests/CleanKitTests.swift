import XCTest
@testable import CleanKit

/// Every test runs against a throwaway home folder; nothing outside it is read for decisions or removed.
final class CleanKitTests: XCTestCase {
    var home = ""
    let now = Date()

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cleankit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        home = dir.resolvingSymlinksInPath().path
        // Assertions read English text; the Chinese test sets its own language.
        L10n.override = .english
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
        L10n.override = nil
    }

    @discardableResult
    func write(_ rel: String, _ text: String = String(repeating: "x", count: 5000), age days: Double = 0) throws -> String {
        let p = home + "/" + rel
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: p, atomically: false, encoding: .utf8)
        try touch(p, age: days)
        return p
    }

    func touch(_ p: String, age days: Double) throws {
        let d = now.addingTimeInterval(-days * 86400)
        try FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: p)
    }

    func context(days: Int = 30, live: Set<String> = [], agentDirs: Set<String> = []) -> ScanContext {
        var o = ScanOptions()
        o.home = home
        o.olderThanDays = days
        o.projectRoots = [home + "/src"]
        return ScanContext(options: o, now: now, processes: ProcessTable(entries: []), agentDirs: agentDirs,
                           liveClaudeSessions: live)
    }

    // MARK: parsing & formatting

    func testCancelledScanStopsAndSaysSo() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home + "/Library/Caches/big", withIntermediateDirectories: true)
        for i in 0..<50 { FileManager.default.createFile(atPath: home + "/Library/Caches/big/f\(i)", contents: Data(count: 4096)) }
        defer { try? FileManager.default.removeItem(atPath: home) }
        var o = ScanOptions(); o.home = home; o.projectRoots = []
        let scanner = DiskScanner(options: o)
        scanner.cancel()
        let started = Date()
        let r = scanner.scan()
        XCTAssertTrue(r.cancelled)
        XCTAssertTrue(r.items.isEmpty, "no job starts once cancelled")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertNil(ScanCancellation.current, "the token is cleared after the scan")
    }

    func testFinishedScanIsNotCancelled() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("done-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        var o = ScanOptions(); o.home = home; o.projectRoots = []
        XCTAssertFalse(DiskScanner(options: o).scan().cancelled)
    }

    func testCancelledSizeWalkStopsEarly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("walk-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for i in 0..<3000 { FileManager.default.createFile(atPath: dir + "/f\(i)", contents: Data(count: 1)) }
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let token = ScanCancellation()
        ScanCancellation.current = token
        defer { ScanCancellation.current = nil }
        XCTAssertEqual(FS.size(dir).files, 3000)
        token.cancel()
        XCTAssertLessThan(FS.size(dir).files, 3000, "a cancelled walk returns early")
    }

    func testParseDays() {
        XCTAssertEqual(parseDays("30"), 30)
        XCTAssertEqual(parseDays("2w"), 14)
        XCTAssertEqual(parseDays("6m"), 180)
        XCTAssertEqual(parseDays("1y"), 365)
        XCTAssertNil(parseDays("abc"))
        XCTAssertNil(parseDays("-3"))
    }

    func testByteFormat() {
        XCTAssertEqual(ByteFormat.string(512), "512 B")
        XCTAssertEqual(ByteFormat.string(1_500_000), "1.5 MB")
        XCTAssertEqual(ByteFormat.string(7_100_000_000), "7.1 GB")
    }

    func testVersionOrder() {
        XCTAssertTrue(AITools.compareVersions("2.1.9", "2.1.10"))
        XCTAssertFalse(AITools.compareVersions("2.1.296", "2.1.29"))
    }

    // MARK: Guard

    func testGuardRefusesProtectedAndOutside() {
        let g = Guard(home: home)
        XCTAssertNotNil(g.refusal(home))
        XCTAssertNotNil(g.refusal(home + "/Library"))
        XCTAssertNotNil(g.refusal(home + "/Documents"))
        XCTAssertNotNil(g.refusal(home + "/.claude/projects"))
        XCTAssertNotNil(g.refusal(home + "/.claude/projects/-x/memory"))
        XCTAssertNotNil(g.refusal(home + "/.claude/projects/-x/memory/MEMORY.md"))
        XCTAssertNotNil(g.refusal("/usr/local/bin"))
        XCTAssertNotNil(g.refusal(home + "/src/app/../../Documents"))
        XCTAssertNotNil(g.refusal(home + "/src/app/.git"))
        XCTAssertNotNil(g.refusal("/private/tmp/claude-\(getuid())/proj"), "only per-session scratch folders")
        XCTAssertNil(g.refusal("/private/tmp/claude-\(getuid())/proj/session-id"))
        XCTAssertNil(g.refusal(home + "/.claude/projects/-x/abc.jsonl"))
        XCTAssertNil(g.refusal(home + "/Library/Caches/Homebrew/foo"))
    }

    // MARK: Claude Code sessions

    func testClaudeSessionsKeepRecentLiveAndMemory() throws {
        let proj = ".claude/projects/-gone-project"
        let old = "11111111-1111-1111-1111-111111111111"
        let recent = "22222222-2222-2222-2222-222222222222"
        let live = "33333333-3333-3333-3333-333333333333"
        let cwd = home + "/src/still-here"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let line = "{\"type\":\"user\",\"cwd\":\"\(cwd)\",\"sessionId\":\"x\"}\n" + String(repeating: "y", count: 4000)
        try write("\(proj)/\(old).jsonl", line, age: 45)
        try write("\(proj)/\(old)/subagents/a.jsonl", age: 45)
        try write(".claude/file-history/\(old)/f1", age: 45)
        try write(".claude/todos/\(old)-agent-\(old).json", age: 45)
        try write("\(proj)/\(recent).jsonl", line, age: 3)
        try write("\(proj)/\(live).jsonl", line, age: 60)
        try write("\(proj)/memory/MEMORY.md", age: 90)
        try write(".claude/history.jsonl", "{\"display\":\"fix the login bug\",\"sessionId\":\"\(old)\",\"project\":\"\(cwd)\"}\n")

        let items = AISessions.claudeCode(context(live: [live]))
        let item = try XCTUnwrap(items.first { $0.id.hasPrefix("claude-sessions/") })
        XCTAssertEqual(item.detail, "~/src/still-here")
        XCTAssertTrue(item.title.contains("still-here"))
        XCTAssertTrue(item.title.contains("1 session"))
        let paths = Set(item.paths)
        XCTAssertTrue(paths.contains(home + "/\(proj)/\(old).jsonl"))
        XCTAssertTrue(paths.contains(home + "/\(proj)/\(old)"))
        XCTAssertTrue(paths.contains(home + "/.claude/file-history/\(old)"))
        XCTAssertTrue(paths.contains(home + "/.claude/todos/\(old)-agent-\(old).json"))
        XCTAssertFalse(paths.contains { $0.contains(recent) }, "recent session kept")
        XCTAssertFalse(paths.contains { $0.contains(live) }, "running session kept")
        XCTAssertFalse(paths.contains { $0.contains("memory") }, "memory never selected")
        XCTAssertTrue(item.note?.contains("1 in use") ?? false)
        XCTAssertTrue(item.note?.contains("fix the login bug") ?? false)
    }

    func testSimplifiedChineseText() throws {
        L10n.override = .simplifiedChinese
        try write(".claude/projects/-nowhere/77777777-7777-7777-7777-777777777777.jsonl", "{\"cwd\":\"\(home)/src/gone\"}\n", age: 40)
        let item = try XCTUnwrap(AISessions.claudeCode(context()).first)
        XCTAssertTrue(item.title.hasSuffix("1 个会话"), item.title)
        XCTAssertTrue(item.detail.hasSuffix("项目文件夹已删除"), item.detail)
        XCTAssertEqual(CleanCategory.aiSessions.title, "AI 会话")
        XCTAssertEqual(AgeFormat.string(now.addingTimeInterval(-3 * 86400), now: now), "3 天前")
    }

    func testClaudeSessionsOfDeletedProjectAreAllStale() throws {
        let sid = "44444444-4444-4444-4444-444444444444"
        try write(".claude/projects/-nowhere/\(sid).jsonl", "{\"cwd\":\"\(home)/src/deleted\"}\n", age: 5)
        let items = AISessions.claudeCode(context())
        let item = try XCTUnwrap(items.first)
        XCTAssertTrue(item.detail.contains("project folder deleted"))
        XCTAssertEqual(item.paths.count, 1)
    }

    func testClaudeOrphanSidecars() throws {
        try write(".claude/projects/-p/55555555-5555-5555-5555-555555555555.jsonl", "{}", age: 1)
        try write(".claude/file-history/66666666-6666-6666-6666-666666666666/f", age: 1)
        try touch(home + "/.claude/file-history/66666666-6666-6666-6666-666666666666", age: 1)
        let items = AISessions.claudeCode(context())
        let orphan = try XCTUnwrap(items.first { $0.id == "claude-orphans" })
        XCTAssertEqual(orphan.paths, [home + "/.claude/file-history/66666666-6666-6666-6666-666666666666"])
        XCTAssertEqual(orphan.safety, .safe)
    }

    // MARK: Codex

    func testCodexGroupsByCwdWithTitles() throws {
        let cwd = home + "/src/api"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"T1\",\"cwd\":\"\(cwd)\"}}\n"
        try write(".codex/sessions/2026/01/01/rollout-a.jsonl", meta, age: 100)
        try write(".codex/sessions/2026/09/30/rollout-b.jsonl", meta.replacingOccurrences(of: "T1", with: "T2"), age: 1)
        try write(".codex/session_index.jsonl", "{\"id\":\"T1\",\"thread_name\":\"add rate limits\"}\n")
        let items = AISessions.codex(context())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].paths, [home + "/.codex/sessions/2026/01/01/rollout-a.jsonl"])
        XCTAssertTrue(items[0].note?.contains("add rate limits") ?? false)
        XCTAssertTrue(items[0].title.hasPrefix("Codex · api"))
    }

    // MARK: editors

    func testEditorWorkspaceOrphans() throws {
        let ws = "Library/Application Support/Cursor/User/workspaceStorage"
        try write("\(ws)/aaa/workspace.json", "{\"folder\":\"file://\(home)/src/gone\"}")
        try write("\(ws)/aaa/state.vscdb", age: 10)
        try FileManager.default.createDirectory(atPath: home + "/src/here", withIntermediateDirectories: true)
        try write("\(ws)/bbb/workspace.json", "{\"folder\":\"file://\(home)/src/here\"}")
        let items = AISessions.editorWorkspaces(context())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].paths, [home + "/\(ws)/aaa"])
    }

    // MARK: tool versions

    func testOldVersionsKeepActiveAndNewest() throws {
        for v in ["2.1.8", "2.1.9", "2.1.10", "2.1.11"] { try write(".local/share/claude/versions/\(v)", age: 5) }
        try FileManager.default.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/.local/bin/claude",
                                                   withDestinationPath: home + "/.local/share/claude/versions/2.1.9")
        let item = try XCTUnwrap(AITools.versions(context()).first)
        XCTAssertEqual(Set(item.paths.map { ($0 as NSString).lastPathComponent }), ["2.1.8", "2.1.10"])
    }

    // MARK: models

    func testOllamaSharedLayersStay() throws {
        let base = ".ollama/models"
        func manifest(_ name: String, _ digests: [String]) throws {
            let layers = digests.map { "{\"digest\":\"sha256:\($0)\"}" }.joined(separator: ",")
            try write("\(base)/manifests/registry.ollama.ai/library/\(name)", "{\"layers\":[\(layers)]}", age: 50)
        }
        try manifest("llama3/8b", ["aaa", "shared"])
        try manifest("llama3/70b", ["bbb", "shared"])
        let big = String(repeating: "z", count: 2_000_000)
        for d in ["aaa", "bbb", "shared", "orphan"] { try write("\(base)/blobs/sha256-\(d)", big, age: 50) }
        let items = AIModels.ollama(context())
        let small = try XCTUnwrap(items.first { $0.id == "ollama/llama3-8b" })
        XCTAssertTrue(small.paths.contains(home + "/\(base)/blobs/sha256-aaa"))
        XCTAssertFalse(small.paths.contains(home + "/\(base)/blobs/sha256-shared"))
        XCTAssertTrue(small.title.contains("llama3:8b"))
        let orphans = try XCTUnwrap(items.first { $0.id == "ollama-orphan-blobs" })
        XCTAssertEqual(orphans.paths, [home + "/\(base)/blobs/sha256-orphan"])
    }

    // MARK: projects

    func testProjectArtifacts() throws {
        let big = String(repeating: "n", count: 1_100_000)
        try write("src/web/package.json", "{}", age: 90)
        try write("src/web/node_modules/left-pad/index.js", big, age: 90)
        try write("src/web/node_modules/left-pad/package.json", "{}", age: 90)
        try touch(home + "/src/web/node_modules/left-pad", age: 90)
        try touch(home + "/src/web/node_modules", age: 90)
        try touch(home + "/src/web", age: 90)
        try write("src/rusty/Cargo.toml", "", age: 0)
        try write("src/rusty/target/debug/app", big, age: 0)
        let items = Projects.scan(context())
        let web = try XCTUnwrap(items.first { $0.title == "web · node_modules" })
        XCTAssertEqual(web.safety, .safe, "stale project")
        let rust = try XCTUnwrap(items.first { $0.title == "rusty · target" })
        XCTAssertEqual(rust.safety, .review, "active project")
        XCTAssertFalse(items.contains { $0.paths.contains { $0.contains("left-pad") } }, "does not descend into artifacts")
    }

    func testLeftoverWorktreeIsSafe() throws {
        try write("src/repo/package.json", "{}")
        try write("src/repo/.claude/worktrees/agent-1/file.txt", age: 10)
        try touch(home + "/src/repo/.claude/worktrees/agent-1", age: 10)
        let items = Projects.scan(context())
        let wt = try XCTUnwrap(items.first { $0.id.hasPrefix("worktree/") })
        XCTAssertEqual(wt.safety, .safe)
        XCTAssertNil(wt.blocked)
        XCTAssertEqual(wt.afterClean?.first?.contains("worktree prune"), true)
    }

    // MARK: path rules, selection, cleaning

    func testPathRuleStaleContents() throws {
        try write("Downloads/old.dmg", age: 60)
        try write("Downloads/new.dmg", age: 1)
        try write("Downloads/notes.txt", age: 60)
        let rule = try XCTUnwrap(Rules.paths.first { $0.id == "old-installers" })
        var o = ScanOptions(); o.home = home
        let item = try XCTUnwrap(DiskScanner(options: o).evaluate(rule, ctx: context(), denied: { _ in }))
        XCTAssertEqual(item.paths, [home + "/Downloads/old.dmg"])
    }

    func testSelection() {
        let r = ScanReport(items: [
            CleanItem(id: "claude-sessions/a", category: .aiSessions, title: "", safety: .review, bytes: 1, paths: ["x"]),
            CleanItem(id: "npm-cache", category: .devCaches, title: "", safety: .safe, bytes: 1, paths: ["x"]),
            CleanItem(id: "worktree/w", category: .aiSessions, title: "", safety: .risky, bytes: 1, paths: ["x"]),
        ], denied: [], started: now, duration: 0)
        XCTAssertEqual(r.select(["safe"]).map(\.id), ["npm-cache"])
        XCTAssertEqual(r.select(["claude-sessions"]).map(\.id), ["claude-sessions/a"])
        XCTAssertEqual(r.select(["ai"]).map(\.id), ["claude-sessions/a"], "risky needs exact id")
        XCTAssertEqual(r.select(["worktree/w"]).map(\.id), ["worktree/w"])
        XCTAssertEqual(r.select(["all"]).count, 2)
    }

    func testSessionPartsAndNarrowing() throws {
        let cwd = home + "/src/api"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let meta = { (id: String) in "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"\(cwd)\"}}\n" + String(repeating: "z", count: 9000) }
        try write(".codex/sessions/2026/01/01/rollout-a.jsonl", meta("A"), age: 100)
        try write(".codex/sessions/2026/02/01/rollout-b.jsonl", meta("B"), age: 60)
        try write(".codex/session_index.jsonl", "{\"id\":\"B\",\"thread_name\":\"newer one\"}\n")
        let item = try XCTUnwrap(AISessions.codex(context()).first)
        let parts = try XCTUnwrap(item.parts)
        XCTAssertEqual(parts.map(\.id), ["B", "A"], "newest first")
        XCTAssertEqual(parts[0].title, "newer one")
        XCTAssertEqual(Set(parts.flatMap(\.paths)), Set(item.paths))

        let onlyA = item.only(["A"])
        XCTAssertEqual(onlyA.paths, [home + "/.codex/sessions/2026/01/01/rollout-a.jsonl"])
        XCTAssertEqual(onlyA.bytes, parts[1].bytes)
        XCTAssertTrue(onlyA.title.hasSuffix("· 1 session"), onlyA.title)

        let r = ScanReport(items: [item], denied: [], started: now, duration: 0)
        XCTAssertEqual(r.select(["\(item.id)#A"]).first?.paths, onlyA.paths)
        XCTAssertTrue(r.select(["\(item.id)#nope"]).isEmpty)
    }

    func testPulseGroupsAppsAndProtectsAgents() {
        let procs = [
            AgentProcess(pid: 10, name: "Google Chrome", executable: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                         cpu: 40, footprintKB: 2_000_000),
            AgentProcess(pid: 11, name: "Google Chrome He", executable: "/Applications/Google Chrome.app/Contents/Frameworks/x.app/Contents/MacOS/Helper",
                         cpu: 30, footprintKB: 1_000_000),
            AgentProcess(pid: 12, name: "ffmpeg", executable: "/opt/homebrew/bin/ffmpeg", argv: ["ffmpeg", "-i", "a"], cpu: 160),
            AgentProcess(pid: 13, name: "2.1.296", executable: "/Users/x/.local/share/claude/versions/2.1.296", argv: ["claude"], cpu: 20),
            AgentProcess(pid: 14, name: "idle", executable: "/usr/bin/idle", cpu: 0.1),
        ]
        let hogs = MachinePulse.group(procs, me: 99)
        XCTAssertEqual(hogs.map(\.name), ["ffmpeg", "Google Chrome", "claude"])
        XCTAssertEqual(hogs[1].pids.sorted(), [10, 11], "helpers fold into the app")
        XCTAssertEqual(hogs[1].memoryKB, 3_000_000)
        XCTAssertEqual(hogs[1].app, "/Applications/Google Chrome.app")
        XCTAssertTrue(hogs[0].quittable)
        XCTAssertFalse(hogs[2].quittable, "agent sessions are never offered")
    }

    func testPulseNamesWhatAnInterpreterRuns() {
        func name(_ argv: [String]) -> String { MachinePulse.programName(ProcessDetails(argv: argv), fallback: "node") }
        XCTAssertEqual(name(["node", "/p/node_modules/.pnpm/vitest@1.6.0/node_modules/vitest/dist/workers/forks.js"]), "vitest")
        XCTAssertEqual(name(["node", "--max-old-space-size=4096", "/p/node_modules/.bin/tsc", "-w"]), "tsc")
        XCTAssertEqual(name(["node", "/p/node_modules/@vitest/runner/dist/index.js"]), "@vitest/runner")
        XCTAssertEqual(name(["python3", "-m", "pytest", "tests"]), "pytest")
        XCTAssertEqual(name(["/usr/bin/python3", "/srv/app/worker.py"]), "worker")
        XCTAssertEqual(name(["ffmpeg", "-i", "a.mov"]), "ffmpeg")
    }

    func testPulseGroupsWorkersByProjectAndKeepsTheirOwner() {
        let c = { (pid: Int32, cwd: String) in
            MachinePulse.Candidate(pid: pid, uid: getuid(), name: "node", cpu: 30, memoryKB: 50_000,
                                   details: ProcessDetails(executable: "/opt/homebrew/bin/node",
                                                           argv: ["node", "/p/node_modules/vitest/vitest.mjs"], cwd: cwd),
                                   owner: "Claude Code")
        }
        let hogs = MachinePulse.group([c(1, "/w/shop"), c(2, "/w/shop"), c(3, "/w/admin")], byMemory: false, me: 99)
        XCTAssertEqual(hogs.count, 2, "one row per project")
        let shop = hogs.first { $0.project == "/w/shop" }
        XCTAssertEqual(shop?.pids.sorted(), [1, 2])
        XCTAssertEqual(shop?.name, "vitest")
        XCTAssertEqual(shop?.owner, "Claude Code")
        XCTAssertEqual(PulseSampler.recognise(name: "2.1.296", executable: "/Users/x/.local/share/claude/versions/2.1.296"), "Claude Code")
        XCTAssertEqual(PulseSampler.recognise(name: "Code Helper", executable: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"), "Visual Studio Code")
        XCTAssertNil(PulseSampler.recognise(name: "zsh", executable: "/bin/zsh"))
    }

    func testPulseNamesACulpritOnlyWhenItExplainsTheLoad() {
        let hog = MachinePulse.Hog(id: "a", name: "ffmpeg", cpu: 160, memoryKB: 100_000, pids: [1], app: nil, quittable: true)
        var p = MachinePulse(load1: 3, load5: 3, cores: 8, thermal: .nominal, memory: .normal, swapUsedMB: 0, hogs: [hog], sampled: now)
        XCTAssertEqual(p.verdict, .ok)
        XCTAssertEqual(p.culpritText, "Mostly ffmpeg, using 1.6 cores")
        p.load1 = 107; p.memory = .warning; p.swapUsedMB = 22 * 1024
        XCTAssertEqual(p.verdict, .overloaded)
        XCTAssertTrue(p.culpritText?.hasPrefix("Memory is tight: 22.0 GB of swap") ?? false, p.culpritText ?? "")
        p.thermal = .serious
        XCTAssertEqual(p.verdict, .hot, "throttling outranks load")
    }

    func testProjectUseIgnoresParentFoldersButNotTheRepoRoot() throws {
        let day: TimeInterval = 86400
        try write("code/mono/.git/HEAD", "ref: refs/heads/main")
        try write("code/mono/packages/web/package.json", "{}")
        try write("code/solo/package.json", "{}")
        let s = ProjectSignals(uses: [
            home + "/code": .init(date: now, source: "Claude Code"),                 // a session in the parent folder
            home + "/code/mono": .init(date: now.addingTimeInterval(-day), source: "Codex"),
        ])
        XCTAssertNil(s.lastUse(of: home + "/code/solo"), "a session in ~/code is not use of every project in it")
        XCTAssertEqual(s.lastUse(of: home + "/code/mono/packages/web")?.source, "Codex", "the repository root counts")
        XCTAssertEqual(s.lastUse(of: home + "/code/mono")?.source, "Codex")
    }

    func testGitActivityReadsTheLastReflogEntry() throws {
        try write("r/.git/logs/HEAD", """
        0000 1111 A <a@x> 1700000000 +0800	commit (initial): one
        1111 2222 A <a@x> 1790000000 +0800	checkout: moving from main to x

        """)
        XCTAssertEqual(ProjectSignals.gitActivity(home + "/r").map { Int($0.timeIntervalSince1970) }, 1_790_000_000)
        XCTAssertNil(ProjectSignals.gitActivity(home + "/nope"))
    }

    func testCleanerRemovesOnlyListedPaths() throws {
        let a = try write("Library/Caches/tool/a")
        let keep = try write("Library/Caches/tool/keep")
        let doc = try write("Documents/report.txt")
        let item = CleanItem(id: "t", category: .devCaches, title: "t", safety: .safe, bytes: 1,
                             paths: [a, home + "/Documents", home + "/../etc"])
        let r = Cleaner.clean(item, mode: .permanent, guard: Guard(home: home))
        XCTAssertEqual(r.removed, [a])
        XCTAssertEqual(r.failed.count, 2)
        XCTAssertFalse(FS.exists(a))
        XCTAssertTrue(FS.exists(keep))
        XCTAssertTrue(FS.exists(doc))
    }

    func testTrashRuleEmptiesTrash() throws {
        let junk = try write(".Trash/old.zip")
        let item = CleanItem(id: "trash", category: .system, title: "Trash", safety: .review, bytes: 1, paths: [junk])
        let r = Cleaner.clean(item, mode: .auto, guard: Guard(home: home))
        XCTAssertEqual(r.removed, [junk])
        XCTAssertFalse(FS.exists(junk), "already in the Trash: removed for good")
    }

    func testModifiedSinceScanIsSkipped() throws {
        let a = try write("Library/Caches/tool/a", age: 0)
        let item = CleanItem(id: "t", category: .devCaches, title: "", safety: .safe, bytes: 1, paths: [a])
        let r = Cleaner.clean(item, mode: .permanent, guard: Guard(home: home), scannedAt: now.addingTimeInterval(-60))
        XCTAssertTrue(r.removed.isEmpty)
        XCTAssertEqual(r.failed[a], "modified since the scan")
        XCTAssertTrue(FS.exists(a))
    }

    func testBlockedItemIsNotCleaned() throws {
        let a = try write("Library/Caches/Google/Chrome/x")
        let item = CleanItem(id: "chrome", category: .browsers, title: "", safety: .safe, bytes: 1, paths: [a],
                             blocked: "quit Google Chrome first")
        let r = Cleaner.clean(item, mode: .permanent, guard: Guard(home: home))
        XCTAssertTrue(r.removed.isEmpty)
        XCTAssertTrue(FS.exists(a))
    }

    func testTreeSizeCountsHardLinksOnce() throws {
        let a = try write("t/a", String(repeating: "q", count: 100_000))
        try FileManager.default.linkItem(atPath: a, toPath: home + "/t/b")
        let s = FS.size(home + "/t")
        XCTAssertEqual(s.files, 1)
        XCTAssertLessThan(s.bytes, 200_000)
    }
}
