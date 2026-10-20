import XCTest
import AgentCore
@testable import CleanKit

/// Every test runs against a throwaway home folder; nothing outside it is read for decisions or removed.
final class CleanKitTests: XCTestCase {
    var home = ""
    let now = Date()

    override func setUpWithError() throws {
        // Fixtures are backdated with utimes, which cannot backdate ctime.
        FS.countsStatusChanges = false
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cleankit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        home = dir.resolvingSymlinksInPath().path
        // Assertions read English text; the Chinese test sets its own language.
        L10n.override = .english
    }

    override func tearDownWithError() throws {
        FS.countsStatusChanges = true
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
        o.sessionRetentionDays = days
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
        // Developer tools can resolve caches outside this fixture HOME (for example go env).
        // The lifecycle assertion needs only the project job, with no configured roots.
        o.categories = [.projects]
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

    func testSessionScanMeasuresOnlyCleanupCandidates() throws {
        let cwd = home + "/src/here"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let group = SessionGroup(cwd: cwd, label: "here", sessions: [
            SessionFile(id: "old", paths: ["old.jsonl", "old-sidecar"], size: TreeSize(), modified: now.addingTimeInterval(-45 * 86400), needsSize: true),
            SessionFile(id: "recent", paths: ["recent.jsonl"], size: TreeSize(), modified: now.addingTimeInterval(-3 * 86400), needsSize: true),
            SessionFile(id: "live", paths: ["live.jsonl"], size: TreeSize(), modified: now.addingTimeInterval(-60 * 86400), needsSize: true),
            SessionFile(id: "active", paths: ["active.jsonl"], size: TreeSize(), modified: now.addingTimeInterval(-3600), needsSize: true)
        ])
        var measured: [[String]] = []
        let items = AISessions.items(tool: "Fixture", idPrefix: "fixture", groups: [group], ctx: context(live: ["live"])) { paths in
            measured.append(paths)
            var size = TreeSize(); size.bytes = 8192; size.files = 2
            return size
        }
        XCTAssertEqual(measured, [["old.jsonl", "old-sidecar"]], "kept sessions must not be walked or queried for private blocks")
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.bytes, 8192)
        XCTAssertEqual(item.files, 2)
        XCTAssertEqual(item.paths, ["old.jsonl", "old-sidecar"])
        XCTAssertTrue(item.note?.contains("3 recent sessions, 2 in use") == true)
        XCTAssertFalse(item.note?.contains("0 B") == true, "unmeasured retained space must not be shown as zero")
    }

    func testSessionScanDoesNoSizingWhenAllSessionsAreKept() throws {
        let cwd = home + "/src/here"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let group = SessionGroup(cwd: cwd, label: "here", sessions: [
            SessionFile(id: "recent", paths: ["recent.jsonl"], size: TreeSize(), modified: now, needsSize: true)
        ])
        let items = AISessions.items(tool: "Fixture", idPrefix: "fixture", groups: [group], ctx: context()) { _ in
            XCTFail("a group with no cleanup candidates must not request sizes")
            return TreeSize()
        }
        XCTAssertTrue(items.isEmpty)
    }

    func testWorktreeOnlyProjectWalkSkipsBuildOutputAndAiderCaches() throws {
        let cwd = home + "/src/here"
        try write("src/here/package.json", "{}")
        try write("src/here/dist/output.js")
        try write("src/here/.aider.tags.cache/file")
        try write("src/here/.claude/worktrees/old/file")
        var options = context().options; options.categories = [.agentWorktrees]
        let scoped = ScanContext(options: options, now: now, processes: ProcessTable(entries: []), agentDirs: [], liveClaudeSessions: [])
        var visited = Set<String>(); var candidates: [Projects.Candidate] = []
        Projects.walk(cwd, depth: 0, ctx: scoped, visited: &visited, into: &candidates)
        XCTAssertEqual(candidates.count, 1)
        if case let .worktree(path, repo) = try XCTUnwrap(candidates.first) {
            XCTAssertEqual(path, cwd + "/.claude/worktrees/old")
            XCTAssertEqual(repo, cwd)
        } else { XCTFail("worktree scans should only offer the worktree") }
    }

    func testOldWorktreeReportsKeepTheirActionsInTheNewCategory() throws {
        let old = CleanItem(id: "worktree/repo/checkout", category: .aiSessions, title: "Old checkout", safety: .risky,
                            bytes: 4096, paths: ["/fixture/checkout"], afterClean: ["git worktree prune"])
        var report = ScanReport(items: [old], denied: [], started: now, duration: 1)
        report.categories = [.aiSessions]
        let decoded = try JSONDecoder().decode(ScanReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded.items.first?.category, .agentWorktrees)
        XCTAssertEqual(decoded.items.first?.safety, .risky)
        XCTAssertEqual(decoded.items.first?.afterClean, old.afterClean)
        XCTAssertEqual(Set(decoded.categories ?? []), [.aiSessions, .agentWorktrees])
        XCTAssertTrue(CleanCategory.agentWorktrees.isAI)
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

    func testDeletedProjectDoesNotOverrideConversationRetention() throws {
        let sid = "44444444-4444-4444-4444-444444444444"
        let path = try write(".claude/projects/-nowhere/\(sid).jsonl", "{\"cwd\":\"\(home)/src/deleted\"}\n", age: 5)
        XCTAssertTrue(AISessions.claudeCode(context()).isEmpty)
        let item = try XCTUnwrap(AISessions.claudeCode(context(days:1)).first)
        XCTAssertTrue(item.detail.contains("project folder deleted"))
        XCTAssertEqual(item.paths,[path])
    }

    func testClaudeOrphanSidecarsRespectAgeAndRequireReview() throws {
        try write(".claude/projects/-p/55555555-5555-5555-5555-555555555555.jsonl", "{}", age: 1)
        try write(".claude/file-history/66666666-6666-6666-6666-666666666666/f", age: 1)
        try touch(home + "/.claude/file-history/66666666-6666-6666-6666-666666666666", age: 1)
        XCTAssertFalse(AISessions.claudeCode(context()).contains { $0.id == "claude-orphans" })
        let items = AISessions.claudeCode(context(days:0))
        let orphan = try XCTUnwrap(items.first { $0.id == "claude-orphans" })
        XCTAssertEqual(orphan.paths, [home + "/.claude/file-history/66666666-6666-6666-6666-666666666666"])
        XCTAssertEqual(orphan.safety, .review)
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
        try write("\(ws)/aaa/workspace.json", "{\"folder\":\"file://\(home)/src/gone\"}", age:40)
        try write("\(ws)/aaa/state.vscdb", age:40)
        try touch(home + "/\(ws)/aaa", age:40)
        try FileManager.default.createDirectory(atPath: home + "/src/here", withIntermediateDirectories: true)
        try write("\(ws)/bbb/workspace.json", "{\"folder\":\"file://\(home)/src/here\"}")
        let items = AISessions.editorWorkspaces(context())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(try XCTUnwrap(items.first).paths, [home + "/\(ws)/aaa"])
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

    func testBuildCachesFoundByTheirContents() throws {
        let big = String(repeating: "x", count: 1_100_000)
        // Xcode project: no marker we know; `build` holds a DMG next to its derived data.
        try write("src/mac/App.xcodeproj/project.pbxproj", "")
        try write("src/mac/build/DerivedData-release/ModuleCache.noindex/m.pcm", big)
        try write("src/mac/build/App.dmg", big)
        // A root `.build` serving an app below it, declared a cache by CACHEDIR.TAG.
        try write("src/tool/apps/x/README.md", "")
        try write("src/tool/.build/CACHEDIR.TAG", "Signature: 8a477f597d28d172789f06886806bc55")
        try write("src/tool/.build/debug/obj.o", big)
        // A film: `out` is the rendered video.
        try write("src/film/film.json", "{}")
        try write("src/film/out/final.mp4", big)
        let items = Projects.scan(context())
        let derived = try XCTUnwrap(items.first { $0.title == "mac · build/DerivedData-release" })
        XCTAssertEqual(derived.regenerable, true)
        XCTAssertFalse(RemovalMode.auto.trashes(derived))
        XCTAssertFalse(items.contains { $0.paths.contains { $0.hasSuffix("/mac/build") } }, "the DMG beside it stays")
        let tool = try XCTUnwrap(items.first { $0.title == "tool · .build" })
        XCTAssertEqual(tool.regenerable, true)
        let film = try XCTUnwrap(items.first { $0.title == "film · out" })
        XCTAssertEqual(film.safety, .review)
        XCTAssertTrue(RemovalMode.auto.trashes(film), "a rendered video goes to the Trash")
    }

    func testNestedTrackedBuildOutputsAreProtected() throws {
        try write("src/repo/packages/web/package.json", "{}")
        try write("src/repo/packages/web/dist/release.js", "release")
        try write("src/repo/packages/web/node_modules/vendor.js", "vendored")
        let repo = home + "/src/repo"
        XCTAssertEqual(Shell.exec(["git", "init", repo], timeout: 5).0, 0)
        XCTAssertEqual(Shell.exec(["git", "-C", repo, "add", "."], timeout: 5).0, 0)
        let protected = Projects.protectedArtifacts(repo + "/packages/web", ["dist", "node_modules", "build"])
        XCTAssertEqual(protected, ["dist", "node_modules"])
    }

    func testUnreadableGitMetadataProtectsAllArtifacts() throws {
        try write("src/broken/.git", "gitdir: /missing/thermo-test-git-directory")
        XCTAssertEqual(Projects.protectedArtifacts(home + "/src/broken", ["target", ".build"]), ["target", ".build"])
    }

    func testRunningAgentBlocksProjectArtifact() throws {
        try write("src/web/package.json", "{}", age: 90)
        try write("src/web/node_modules/output", String(repeating: "x", count: 1_100_000), age: 90)
        let dir = home + "/src/web"
        let item = try XCTUnwrap(Projects.make(.artifact(project: dir, kind: "Node", name: "node_modules",
                                                       activity: now.addingTimeInterval(-90 * 86400), source: nil),
                                             ctx: context(agentDirs: [dir + "/src"])))
        XCTAssertEqual(item.blocked, "an agent is running in it")
    }

    func testExplicitProjectRootsStayWithinScopeAndEmitItems() throws {
        let big = String(repeating: "x", count: 1_100_000)
        try write("src/web/package.json", "{}")
        try write("src/web/node_modules/output", big)
        let other = home + "/elsewhere/project"
        try write("elsewhere/project/package.json", "{}")
        try write("elsewhere/project/node_modules/output", big)
        try write(".claude/projects/other/session.jsonl", "{\"cwd\":\"\(other)\"}\n")
        var ctx = context()
        var options = ctx.options
        options.discoverProjectRoots = false
        ctx = ScanContext(options: options, now: now, processes: ctx.processes, agentDirs: [], liveClaudeSessions: [])
        let lock = NSLock()
        var emitted: [String] = []
        let items = Projects.scan(ctx, onItem: { item in
            lock.lock(); emitted.append(item.id); lock.unlock()
        })
        XCTAssertFalse(items.isEmpty)
        XCTAssertFalse(items.contains { $0.group == other })
        XCTAssertEqual(Set(emitted), Set(items.map(\.id)))
        options.discoverProjectRoots = true
        let expanded = Projects.scan(ScanContext(options: options, now: now, processes: ctx.processes, agentDirs: [], liveClaudeSessions: []))
        XCTAssertTrue(expanded.contains { $0.group == other })
    }

    func testCleaningRechecksNewlyTrackedProjectOutput() throws {
        let dir = home + "/src/repo"
        let path = try write("src/repo/dist/release.js", "must survive")
        XCTAssertEqual(Shell.exec(["git", "init", dir], timeout: 5).0, 0)
        let item = CleanItem(id: "project/test", category: .projects, title: "dist", safety: .review,
                             bytes: 4096, paths: [dir + "/dist"], group: dir)
        XCTAssertEqual(Shell.exec(["git", "-C", dir, "add", "."], timeout: 5).0, 0)
        let result = Cleaner.clean(item, mode: .permanent, guard: Guard(home: home))
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertFalse(result.failed.isEmpty)
        XCTAssertTrue(FS.exists(path))
    }

    func testLinkedWorktreeOutsideItsRepositoryIsFound() throws {
        try write("src/repo/.git/worktrees/w1/gitdir", home + "/src/scratch/source/.git\n")
        try write("src/scratch/source/.git", "gitdir: " + home + "/src/repo/.git/worktrees/w1\n")
        try write("src/scratch/source/file.txt")
        try write("src/plain/.git", "not a worktree\n")
        var options = context().options; options.categories = [.agentWorktrees]
        let scoped = ScanContext(options: options, now: now, processes: ProcessTable(entries: []), agentDirs: [], liveClaudeSessions: [])
        var visited = Set<String>(); var candidates: [Projects.Candidate] = []
        Projects.walk(home + "/src", depth: 0, ctx: scoped, visited: &visited, into: &candidates)
        let found = candidates.compactMap { c -> (String, String)? in if case let .worktree(p, r) = c { return (p, r) }; return nil }
        XCTAssertEqual(found.map(\.0), [home + "/src/scratch/source"])
        XCTAssertEqual(found.first?.1, home + "/src/repo")
        XCTAssertNil(Projects.linkedWorktreeRepository(home + "/src/plain"))
    }

    func testLeftoverWorktreeRequiresReviewAndAvoidsGlobalPrune() throws {
        try write("src/repo/package.json", "{}")
        try write("src/repo/.claude/worktrees/agent-1/file.txt", age: 10)
        try touch(home + "/src/repo/.claude/worktrees/agent-1", age: 10)
        let items = Projects.scan(context())
        let wt = try XCTUnwrap(items.first { $0.id.hasPrefix("worktree/") })
        XCTAssertEqual(wt.safety, .review)
        XCTAssertNil(wt.blocked)
        XCTAssertNil(wt.afterClean)
        XCTAssertFalse(wt.automaticallySelected)
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

    func testRecentlyMovedFileIsNotStale() throws {
        FS.countsStatusChanges = true
        try write("Downloads/unpacked.dmg", age: 60)
        let rule = try XCTUnwrap(Rules.paths.first { $0.id == "old-installers" })
        var o = ScanOptions(); o.home = home
        XCTAssertNil(DiskScanner(options: o).evaluate(rule, ctx: context(), denied: { _ in }),
                     "an old modification date on a file that just arrived is not age")
    }

    func testFolderOfAnotherRuleIsCountedOnce() throws {
        try write("Library/Logs/JetBrains/idea.log", age: 60)
        try write("Library/Logs/Other/app.log", age: 60)
        let rule = try XCTUnwrap(Rules.paths.first { $0.id == "user-logs" })
        var o = ScanOptions(); o.home = home
        let item = try XCTUnwrap(DiskScanner(options: o).evaluate(rule, ctx: context(), denied: { _ in }))
        XCTAssertEqual(item.paths, [home + "/Library/Logs/Other"])
    }

    func testKeepsNewestDeviceSupport() throws {
        let base = "Library/Developer/Xcode/iOS DeviceSupport/"
        try write(base + "16.0/a", age: 300)
        try write(base + "17.0/a", age: 200)
        try write(base + "18.0/a", age: 100)
        let rule = try XCTUnwrap(Rules.paths.first { $0.id == "xcode-device-support" })
        var o = ScanOptions(); o.home = home
        let item = try XCTUnwrap(DiskScanner(options: o).evaluate(rule, ctx: context(), denied: { _ in }))
        XCTAssertEqual(item.paths, [home + "/" + base + "16.0"])
    }

    func testChromeProfileCachesExpandProfiles() throws {
        let chrome = "Library/Application Support/Google/Chrome/"
        try write(chrome + "Default/Code Cache/js/a")
        try write(chrome + "Profile 2/GPUCache/data_0")
        try write(chrome + "Default/History", "keep")
        let rule = try XCTUnwrap(Rules.paths.first { $0.id == "chrome-profile-caches" })
        var o = ScanOptions(); o.home = home
        let item = try XCTUnwrap(DiskScanner(options: o).evaluate(rule, ctx: context(), denied: { _ in }))
        XCTAssertEqual(Set(item.paths), [home + "/" + chrome + "Default/Code Cache/js", home + "/" + chrome + "Profile 2/GPUCache/data_0"])
    }

    func testCleanerSkipsReplacedAndOpenPaths() throws {
        let replaced = try write("Library/Caches/demo/replaced")
        let held = home + "/Library/Caches/demo/held"
        try FileManager.default.createDirectory(atPath: held, withIntermediateDirectories: true)
        let free = try write("Library/Caches/demo/free")
        var item = CleanItem(id: "test", category: .system, title: "", safety: .safe, bytes: 1, paths: [replaced, held, free])
        item.identities = Dictionary(uniqueKeysWithValues: item.paths.map { ($0, FileIdentity.of($0)!) })
        try FileManager.default.removeItem(atPath: replaced)
        _ = try write("Library/Caches/demo/replaced")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["20"]
        p.currentDirectoryURL = URL(fileURLWithPath: held)
        try p.run()
        defer { p.terminate() }
        Thread.sleep(forTimeInterval: 0.2)
        let result = Cleaner.clean(item, mode: .permanent, guard: Guard(home: home))
        XCTAssertEqual(result.removed, [free])
        XCTAssertNotNil(result.failed[replaced])
        XCTAssertEqual(result.failed[held], tr("%1$@ has files open here", "sleep"))
        XCTAssertTrue(FS.exists(replaced) && FS.exists(held))
    }

    func testSelection() {
        let r = ScanReport(items: [
            CleanItem(id: "claude-sessions/a", category: .aiSessions, title: "", safety: .review, bytes: 1, paths: ["x"]),
            CleanItem(id: "npm-cache", category: .devCaches, title: "", safety: .safe, bytes: 1, paths: ["x"]),
            CleanItem(id: "worktree/w", category: .aiSessions, title: "", safety: .risky, bytes: 1, paths: ["x"]),
        ], denied: [], started: now, duration: 0)
        XCTAssertEqual(r.select(["safe"]).map(\.id), [], "Regenerable development dependencies are preserved by automatic selection")
        XCTAssertEqual(r.select(["npm-cache"]).map(\.id), ["npm-cache"])
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

    func testPulseRowCountsEveryProcessAndNamesOtherFolders() {
        // 3 big and 3 small copies in one folder, 2 more in another: the row sums all 6 of its own,
        // not just the big ones, and says where the other 2 are.
        let c = { (pid: Int32, cwd: String, kb: Int, owner: String?) in
            MachinePulse.Candidate(pid: pid, uid: getuid(), name: "node", cpu: 0, memoryKB: kb,
                                   details: ProcessDetails(executable: "/opt/homebrew/bin/node",
                                                           argv: ["node", "/p/node_modules/.bin/rea", "mcp"], cwd: cwd),
                                   owner: owner, residentKB: 1024, ppid: pid == 6 ? 1 : 500)
        }
        let procs = [c(1, "/w/a", 250_000, "Codex"), c(2, "/w/a", 250_000, "Codex"), c(3, "/w/a", 250_000, "Claude Code"),
                     c(4, "/w/a", 2_000, "Codex"), c(5, "/w/a", 2_000, "Codex"), c(6, "/w/a", 2_000, nil),
                     c(7, "/w/b", 2_000, "Codex"), c(8, "/w/b", 2_000, "Codex")]
        let hogs = MachinePulse.group(procs, byMemory: true, me: 99)
        let a = hogs.first { $0.project == "/w/a" }
        XCTAssertEqual(a?.pids.sorted(), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(a?.processCount, 6)
        XCTAssertEqual(a?.memoryKB, 756_000)
        XCTAssertEqual(a?.residentKB, 6 * 1024)
        XCTAssertNil(a?.owner, "owners disagree, so the row claims none")
        XCTAssertEqual(a?.owners, ["Codex", "Claude Code", "unknown"])
        XCTAssertEqual(a?.parts?.first { $0.pid == 6 }?.ppid, 1)
        XCTAssertEqual(a?.parts?.first { $0.pid == 3 }?.owner, "Claude Code")
        XCTAssertEqual(a?.elsewhere?.processes, 2)
        XCTAssertEqual(a?.elsewhere?.projects, ["/w/b"])
        XCTAssertEqual(a?.elsewhere?.memoryKB, 4_000)
        XCTAssertNil(hogs.first { $0.project == "/w/b" }, "a program below the size threshold as a whole stays off the list")
        let all = MachinePulse.group(procs, byMemory: true, me: 99, limit: nil)
        XCTAssertEqual(all.reduce(0) { $0 + $1.pids.count }, 8)
    }

    func testPulseHistoryKeepsProcessCountsAndOldLinesStillDecode() throws {
        var hog = MachinePulse.Hog(id: "cmd:rea|/w", name: "rea", cpu: 0, memoryKB: 3_000_000, pids: [1, 2, 3], app: nil, quittable: true)
        hog.memoryMetric = .footprint
        let pulse = MachinePulse(load1: 9, load5: 9, cores: 8, thermal: .nominal, memory: .warning, swapUsedMB: 0, hogs: [hog], sampled: now)
        let record = PulseRecord(pulse, memory: nil)
        XCTAssertEqual(record.top.first?.processes, 3)
        let share = PulseHistory.blame([record]).first
        XCTAssertEqual(share?.peakProcesses, 3)
        XCTAssertEqual(share?.memoryMetric, .footprint)
        let old = #"{"name":"rea","cpu":0,"memoryKB":10}"#
        XCTAssertNil(try JSONDecoder().decode(PulseRecord.Program.self, from: Data(old.utf8)).processes)
    }

    func testRetainedSwapDoesNotExplainSlownessWhenPressureAndLoadAreNormal() {
        let hog = MachinePulse.Hog(id: "fixture", name: "Fixture", cpu: 1, memoryKB: 200_000, pids: [42], app: nil, quittable: true)
        let pulse = MachinePulse(load1: 0.5, load5: 0.5, cores: 8, thermal: .nominal, memory: .normal,
                                 swapUsedMB: 16 * 1024, hogs: [hog], sampled: now)
        XCTAssertEqual(pulse.verdict, .ok)
        XCTAssertNil(pulse.culpritText)
    }

    func testPulseReportsSignificantCPUAndObservedMemoryContext() {
        let hog = MachinePulse.Hog(id: "a", name: "ffmpeg", cpu: 160, memoryKB: 100_000, pids: [1], app: nil, quittable: true)
        var p = MachinePulse(load1: 3, load5: 3, cores: 8, thermal: .nominal, memory: .normal, swapUsedMB: 0, hogs: [hog], sampled: now)
        XCTAssertEqual(p.verdict, .ok)
        XCTAssertTrue(p.culpritText?.contains("ffmpeg") == true)
        XCTAssertTrue(p.culpritText?.contains("1.6") == true)
        p.load1 = 107; p.memory = .warning; p.swapUsedMB = 22 * 1024
        XCTAssertEqual(p.verdict, .overloaded)
        XCTAssertTrue(p.culpritText?.contains(MemoryFormat.string(mebibytes: 22 * 1024)) == true)
        XCTAssertTrue(p.culpritText?.contains("high memory pressure") == true)
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

    func testSavedReportIsReusedOnlyWhileFresh() {
        var r = ScanReport(items: [CleanItem(id: "npm-cache", category: .devCaches, title: "", safety: .safe, bytes: 1, paths: ["x"])],
                           denied: [], started: now, duration: 1)
        r.categories = [.devCaches]
        r.olderThanDays = 30
        ScanReportCache.save(r, home: home)
        let back = ScanReportCache.load(home: home, maxAge: 900, now: now.addingTimeInterval(60))
        XCTAssertEqual(back?.items.map(\.id), ["npm-cache"])
        XCTAssertEqual(back?.categories, [.devCaches])
        XCTAssertNil(ScanReportCache.load(home: home, maxAge: 900, now: now.addingTimeInterval(1000)), "stale")
        var stopped = r
        stopped.cancelled = true
        stopped.items = []
        ScanReportCache.save(stopped, home: home)
        XCTAssertEqual(ScanReportCache.load(home: home, maxAge: 900, now: now)?.items.count, 1, "a stopped scan never replaces a finished one")
    }

    func testPulseSplitsBrowsersAndSuggestsARestart() {
        let chrome = "/Applications/Google Chrome.app/Contents"
        func p(_ pid: Int32, _ role: [String], gb: Double, hours: Double) -> MachinePulse.Candidate {
            MachinePulse.Candidate(pid: pid, uid: getuid(), name: "Google Chrome", cpu: 10, memoryKB: Int(gb * 1_048_576),
                                   details: ProcessDetails(executable: chrome + "/Frameworks/Helper.app/Contents/MacOS/Helper",
                                                           argv: ["Helper"] + role, cwd: "/"),
                                   residentKB: Int(gb * 1_048_576 / 10), uptime: hours * 3600)
        }
        let procs = [
            p(1, [], gb: 0.5, hours: 31),
            p(2, ["--type=gpu-process"], gb: 2.4, hours: 30),
            p(3, ["--type=renderer", "--renderer-client-id=1975"], gb: 1.5, hours: 1),
            p(4, ["--type=renderer", "--extension-process", "--renderer-client-id=12"], gb: 0.4, hours: 30),
            p(5, ["--type=utility", "--utility-sub-type=network.mojom.NetworkService"], gb: 0.3, hours: 30),
        ]
        let hogs = MachinePulse.group(procs, byMemory: true, me: 99)
        let c = hogs.first { $0.name == "Google Chrome" }!
        XCTAssertEqual(c.parts?.map(\.role), ["GPU", "renderer", "main", "extension", "network"], "all processes remain inspectable")
        XCTAssertEqual(c.pagesOpened, 1975)
        XCTAssertEqual(c.uptime, 31 * 3600)
        XCTAssertNil(c.advice, "a footprint/RSS ratio is not evidence of swapped memory")

        // Fresh, or mostly resident: nothing to suggest.
        XCTAssertNil(MachinePulse.group(procs.map { var x = $0; x.uptime = 3600; return x }, byMemory: true, me: 99).first?.advice)
        XCTAssertNil(MachinePulse.group(procs.map { var x = $0; x.residentKB = x.memoryKB; return x }, byMemory: true, me: 99).first?.advice)
    }

    func testPulseExplainsSwapAndItsDiskSpace() {
        let big = MachinePulse.Hog(id: "c", name: "Google Chrome", cpu: 100, memoryKB: 19 * 1_048_576, pids: [1], app: "/Applications/Google Chrome.app", quittable: true)
        var p = MachinePulse(load1: 66, load5: 45, cores: 8, thermal: .nominal, memory: .warning, swapUsedMB: 27 * 1024,
                             swapTotalMB: 28 * 1024, hogs: [big], sampled: now)
        XCTAssertTrue(p.culpritText?.contains(MemoryFormat.string(mebibytes: 27 * 1024)) == true)
        XCTAssertTrue(p.culpritText?.contains("Google Chrome") == true)
        XCTAssertTrue(p.culpritText?.contains(MemoryFormat.string(kibibytes: 19 * 1_048_576)) == true)
        XCTAssertTrue(p.swapDiskText?.contains(MemoryFormat.string(mebibytes: 28 * 1024)) == true)
        p.swapTotalMB = 2048
        XCTAssertNil(p.swapDiskText, "small swap is not worth a word")
    }

    func record(_ minutesAgo: Double, load: Double = 2, memory: MachinePulse.Memory = .normal, swapGB: Double = 1,
                thermal: MachinePulse.Thermal = .nominal, top: [(String, Double, Double)] = []) -> PulseRecord {
        PulseRecord(t: now.addingTimeInterval(-minutesAgo * 60), load1: load, cores: 8, memory: memory,
                    swapUsedMB: Int(swapGB * 1024), swapTotalMB: Int(swapGB * 1024), thermal: thermal,
                    top: top.map { .init(name: $0.0, cpu: $0.1, memoryKB: Int($0.2 * 1_048_576), project: nil, owner: nil) })
    }

    func testHistoryKeepsOnly24Hours() throws {
        let h = PulseHistory(url: URL(fileURLWithPath: home + "/hist/pulse-history.jsonl"))
        h.append(record(26 * 60), now: now)            // first append compacts: this one is already too old
        h.append(record(23 * 60), now: now)
        h.append(record(5), now: now)
        try "not json\n".write(toFile: home + "/x", atomically: true, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: h.url); handle.seekToEndOfFile(); handle.write(Data("garbage\n".utf8)); try handle.close()
        h.compact(now: now)
        let all = h.records(since: .distantPast)
        XCTAssertEqual(all.count, 2, "older than a day and unreadable lines are dropped")
        XCTAssertEqual(h.records(since: now.addingTimeInterval(-3600)).count, 1)
        let lines = try String(contentsOf: h.url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "the file itself is cut back")
    }

    func testBlameCountsOnlyStrugglingMinutes() {
        let recs = [
            record(30, load: 2, top: [("idle-app", 10, 1)]),                          // not struggling (load < cores)
            record(3, load: 20, memory: .warning, top: [("Google Chrome", 120, 19), ("ffmpeg", 190, 1)]),
            record(2, load: 20, memory: .warning, top: [("Google Chrome", 130, 19)]),
            record(1, load: 20, memory: .warning, top: [("Google Chrome", 140, 19)]),
        ]
        let b = PulseHistory.blame(recs)
        XCTAssertEqual(b.first?.name, "Google Chrome")
        XCTAssertEqual(b.first?.minutes, 3)
        XCTAssertEqual(b.first?.peakCPU, 140)
        XCTAssertNil(b.first { $0.name == "idle-app" }, "a calm Mac blames nobody")
    }

    func testAlertsFireOnceAnHourAndNeedTheFullWindow() {
        var alerts = SlowdownAlerts()
        let calm = MachinePulse(load1: 2, load5: 2, cores: 8, thermal: .nominal, memory: .normal, swapUsedMB: 0, hogs: [], sampled: now)
        // CPU hog for only 5 minutes: not yet.
        let five = (0...5).map { record(Double(5 - $0), load: 12, top: [("ffmpeg", 190, 1)]) }
        XCTAssertTrue(alerts.evaluate(five, latest: calm, now: now).isEmpty)
        // Ten minutes: told once.
        let ten = (0...10).map { record(Double(10 - $0), load: 12, top: [("ffmpeg", 190, 1)]) }
        XCTAssertEqual(alerts.evaluate(ten, latest: calm, now: now).map(\.key), ["cpu:ffmpeg"])
        XCTAssertTrue(alerts.evaluate(ten, latest: calm, now: now.addingTimeInterval(60)).isEmpty, "cooldown")
        let later = ten.map { var r = $0; r.t = r.t.addingTimeInterval(3700); return r }
        XCTAssertEqual(alerts.evaluate(later, latest: calm, now: now.addingTimeInterval(3700)).map(\.key), ["cpu:ffmpeg"], "an hour later, again")

        // Swap over 8 GB and growing, with the restart advice of the biggest program.
        var a2 = SlowdownAlerts()
        let chrome = MachinePulse.Hog(id: "c", name: "Google Chrome", cpu: 100, memoryKB: 19 * 1_048_576, pids: [1], app: "/Applications/Google Chrome.app",
                                      quittable: true, advice: .init(kind: "restart", text: "restart Chrome", freesKB: 19 * 1_048_576))
        let latest = MachinePulse(load1: 60, load5: 40, cores: 8, thermal: .nominal, memory: .warning, swapUsedMB: 27 * 1024, hogs: [chrome], sampled: now)
        let swap = [record(10, swapGB: 20), record(0, swapGB: 27)]
        let fired = a2.evaluate(swap, latest: latest, now: now)
        XCTAssertEqual(fired.map(\.key), ["swap"])
        XCTAssertTrue(fired[0].body.contains("restart Chrome"))
        XCTAssertEqual(fired[0].program, "Google Chrome")
        // Not growing: quiet.
        var a3 = SlowdownAlerts()
        XCTAssertTrue(a3.evaluate([record(10, swapGB: 27), record(0, swapGB: 27)], latest: latest, now: now).isEmpty)
    }

    func testDiskAlertsComeEarlyAndWhenFillingFast() {
        func disk(_ minutesAgo: Double, _ gb: Double, swapGB: Double = 1) -> PulseRecord {
            var r = record(minutesAgo, swapGB: swapGB); r.diskFreeBytes = Int64(gb * 1e9); return r
        }
        let calm = MachinePulse(load1: 2, load5: 2, cores: 8, thermal: .nominal, memory: .normal, swapUsedMB: 0, hogs: [], sampled: now)
        var alerts = SlowdownAlerts()
        XCTAssertTrue(alerts.evaluate([disk(0, 80)], latest: calm, now: now).isEmpty)
        // Under 30 GB: told, then quiet for twelve hours.
        XCTAssertEqual(alerts.evaluate([disk(0, 25)], latest: calm, now: now).map(\.key), ["disk:30"])
        XCTAssertTrue(alerts.evaluate([disk(0, 25)], latest: calm, now: now.addingTimeInterval(3700)).isEmpty)
        // Under 5 GB: a new step, and it repeats hourly; swap is named as part of the cause.
        let low = alerts.evaluate([disk(0, 4, swapGB: 18)], latest: calm, now: now.addingTimeInterval(4000))
        XCTAssertEqual(low.map(\.key), ["disk:5"])
        XCTAssertTrue(low[0].body.contains("Swap"))
        XCTAssertEqual(alerts.evaluate([disk(0, 4)], latest: calm, now: now.addingTimeInterval(7700)).map(\.key), ["disk:5"])

        // 60 GB free but 12 GB written in ten minutes: full in under an hour.
        var fast = SlowdownAlerts()
        let filling = fast.evaluate([disk(10, 72), disk(0, 60)], latest: calm, now: now)
        XCTAssertEqual(filling.map(\.key), ["disk:filling"])
        // A slow drift is not news.
        var slow = SlowdownAlerts()
        XCTAssertTrue(slow.evaluate([disk(10, 61), disk(0, 60)], latest: calm, now: now).isEmpty)
        // Older history without disk numbers stays quiet.
        var old = SlowdownAlerts()
        XCTAssertTrue(old.evaluate([record(0)], latest: calm, now: now).isEmpty)
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

    func testRebuildableBuildOutputIsDeletedNotTrashed() throws {
        // Recent `.build` is reviewed (rebuilding costs time) but the Trash would free nothing.
        let build = try write("code/app/.build/debug/app.o", age: 0)
        var item = CleanItem(id: "project/app-.build", category: .projects, title: "app · .build", safety: .review, bytes: 1,
                             paths: [home + "/code/app/.build"])
        item.regenerable = true
        XCTAssertFalse(RemovalMode.auto.trashes(item))
        XCTAssertTrue(RemovalMode.trash.trashes(item), "an explicit --trash still wins")
        let r = Cleaner.clean(item, mode: .auto, guard: Guard(home: home))
        XCTAssertEqual(r.removed, [home + "/code/app/.build"])
        XCTAssertNil(r.trashBatchID)
        XCTAssertFalse(FS.exists(build))
        XCTAssertFalse(FS.exists(home + "/.Trash/.build"))
        // `out` may hold a rendered video: still the Trash.
        var out = item; out.regenerable = false
        XCTAssertTrue(RemovalMode.auto.trashes(out))
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

    func testHardLinkedFilesOnlyCountWhenEveryLinkGoes() throws {
        // pnpm/bun style: node_modules links into a store outside it, so deleting it frees nothing.
        let store = try write("store/pkg.js", String(repeating: "s", count: 100_000))
        try FileManager.default.createDirectory(atPath: home + "/proj/node_modules", withIntermediateDirectories: true)
        try FileManager.default.linkItem(atPath: store, toPath: home + "/proj/node_modules/pkg.js")
        try write("proj/node_modules/own.js", String(repeating: "o", count: 100_000))
        let nm = FS.size(home + "/proj/node_modules")
        XCTAssertEqual(nm.files, 2)
        XCTAssertGreaterThan(nm.allocated, nm.bytes, "the linked file takes space but would not be freed")
        XCTAssertLessThan(nm.bytes, 150_000, "only own.js is reclaimable")
        let both = FS.size(home)
        XCTAssertGreaterThan(both.bytes, 150_000, "with the store included, every link goes")
    }

    func testTreeSizeCountsHardLinksOnce() throws {
        let a = try write("t/a", String(repeating: "q", count: 100_000))
        try FileManager.default.linkItem(atPath: a, toPath: home + "/t/b")
        let s = FS.size(home + "/t")
        XCTAssertEqual(s.files, 1)
        XCTAssertLessThan(s.bytes, 200_000)
    }
}

final class CleanReportInvalidationTests: XCTestCase {
    func testInvalidationDropsSavedScan() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let report = ScanReport(items: [], denied: [], started: Date(), duration: 1)
        ScanReportCache.save(report, home: home.path)
        XCTAssertNotNil(ScanReportCache.load(home: home.path, maxAge: 3600))
        ScanReportCache.invalidate(home: home.path)
        XCTAssertNil(ScanReportCache.load(home: home.path, maxAge: 3600))
    }
}

final class SpaceCancellationTests: XCTestCase {
    func testExplicitCancellationDoesNotInheritAnotherScansToken() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(repeating: 1, count: 8192).write(to: home.appendingPathComponent("fixture"))
        let previous = ScanCancellation.current
        let cancelled = ScanCancellation()
        cancelled.cancel()
        ScanCancellation.current = cancelled
        defer { ScanCancellation.current = previous }
        let independent = ScanCancellation()
        XCTAssertGreaterThan(FS.size(home.path, cancellation: independent).allocated, 0)
        XCTAssertEqual(FS.size(home.path, cancellation: cancelled).files, 0)
    }

    func testPreCancelledOverviewDoesNotPublishOrCachePartialResults() throws {
        let token = ScanCancellation()
        token.cancel()
        var published = 0
        let overview = SpaceOverview.measure(home: NSTemporaryDirectory(), onEntry: { _ in published += 1 }, cancellation: token)
        XCTAssertEqual(overview.cancelled, true)
        XCTAssertTrue(overview.entries.isEmpty)
        XCTAssertEqual(published, 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let previous = Data("previous complete cache".utf8)
        try previous.write(to: url)
        overview.save(to: url)
        XCTAssertEqual(try Data(contentsOf: url), previous)
    }
}

extension CleanKitTests {
    func testDefaultConversationCleanupKeepsOldTranscriptsUntilAgeIsChosen() throws {
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"old-fixture\",\"cwd\":\"\(home)/missing-project\"}}\n"
        let path = try write(".codex/sessions/2026/01/01/rollout-old.jsonl",meta,age:100)
        var options = ScanOptions(); options.home = home; options.projectRoots = []
        let ctx = ScanContext(options:options,now:now,processes:.init(entries:[]),agentDirs:[],liveClaudeSessions:[])
        XCTAssertTrue(AISessions.scan(ctx).filter { $0.category == .aiSessions }.isEmpty)
        XCTAssertTrue(FS.exists(path))
    }
}

extension CleanKitTests {
    func testConversationRetentionIsIndependentOfCacheAgeAndNeverAutoSelectsChats() throws {
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"fixture\",\"cwd\":\"\(home)/missing-project\"}}\n"
        let oldest = try write(".codex/sessions/2026/01/01/rollout-oldest.jsonl",meta,age:100)
        let month = try write(".codex/sessions/2026/01/01/rollout-month.jsonl",meta,age:40)
        _ = try write(".codex/sessions/2026/01/01/rollout-recent.jsonl",meta,age:5)
        var o = ScanOptions(); o.home = home; o.olderThanDays = 1
        for (age,expected) in [(90,Set([oldest])),(30,Set([oldest,month]))] {
            o.sessionRetentionDays = age
            let ctx = ScanContext(options:o,now:now,processes:.init(entries:[]),agentDirs:[],liveClaudeSessions:[])
            let items = AISessions.scan(ctx).filter { $0.category == .aiSessions }
            XCTAssertEqual(Set(items.flatMap(\.paths)),expected)
            XCTAssertTrue(items.allSatisfy { !$0.automaticallySelected })
        }
    }
    func testKeepAllSkipsOldTranscriptSizingAndStillFindsMaintenanceLogs() throws {
        var o = ScanOptions(); o.home = home
        let ctx = ScanContext(options:o,now:now,processes:.init(entries:[]),agentDirs:[],liveClaudeSessions:[])
        let group = SessionGroup(cwd:home,label:"fixture",sessions:[SessionFile(id:"old",paths:["old.jsonl"],size:TreeSize(),modified:now.addingTimeInterval(-100*86400),needsSize:true)])
        XCTAssertTrue(AISessions.items(tool:"Fixture",idPrefix:"fixture",groups:[group],ctx:ctx,measure:{ _ in
            XCTFail("keep-all must not measure old transcripts"); return TreeSize()
        }).isEmpty)
        try write(".local/share/opencode/log/old.log",age:3)
        let items = AISessions.scan(ctx)
        XCTAssertTrue(items.contains { $0.id == "opencode-logs" && $0.category == .aiCaches })
        XCTAssertFalse(items.contains { $0.category == .aiSessions })
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"fixture\",\"cwd\":\"\(home)/missing\"}}\n"
        try write(".codex/sessions/2026/01/01/rollout-old.jsonl",meta,age:100)
        o.sessionRetentionDays = 30
        let optedIn = ScanContext(options:o,now:now,processes:.init(entries:[]),agentDirs:[],liveClaudeSessions:[])
        XCTAssertTrue(AISessions.scan(optedIn).contains { $0.category == .aiSessions })
        o.categories = [.aiCaches]
        let cacheOnly = ScanContext(options:o,now:now,processes:.init(entries:[]),agentDirs:[],liveClaudeSessions:[])
        XCTAssertTrue(AISessions.scan(cacheOnly).contains { $0.id == "opencode-logs" })
        XCTAssertFalse(AISessions.scan(cacheOnly).contains { $0.category == .aiSessions })
    }
    func testScannerWritesExplicitConversationPolicyAndLegacyDecoderKeepsItUnknown() throws {
        var o = ScanOptions(); o.home = home; o.projectRoots = []; o.discoverProjectRoots = false; o.categories = [.aiSessions]
        let report = DiskScanner(options:o).scan()
        XCTAssertEqual(report.sessionPolicyVersion,ScanOptions.sessionPolicyVersion); XCTAssertNil(report.sessionRetentionDays)
        let old = Data("{\"items\":[],\"denied\":[],\"started\":0,\"duration\":0}".utf8)
        let legacy = try JSONDecoder().decode(ScanReport.self,from:old)
        XCTAssertNil(legacy.sessionPolicyVersion); XCTAssertNil(legacy.sessionRetentionDays)
    }
}

extension CleanKitTests {
    func testConversationAuxiliaryCopiesRespectAgeAndRequireReview() throws {
        try FileManager.default.createDirectory(atPath:home+"/.claude/projects",withIntermediateDirectories:true)
        let old = home+"/.claude/file-history/88888888-8888-8888-8888-888888888888"
        let recent = home+"/.claude/file-history/99999999-9999-9999-9999-999999999999"
        try write(String(old.dropFirst(home.count+1))+"/payload",age:100);try touch(old,age:100)
        try write(String(recent.dropFirst(home.count+1))+"/payload",age:5);try touch(recent,age:100)
        let oldBackup = home+"/.claude/projects-backup-old", recentBackup = home+"/.claude/projects-backup-recent"
        try write(".claude/projects-backup-old/payload",age:100);try touch(oldBackup,age:100)
        try write(".claude/projects-backup-recent/payload",age:5);try touch(recentBackup,age:100)
        let items = AISessions.claudeCode(context())
        let orphan = try XCTUnwrap(items.first { $0.id == "claude-orphans" })
        XCTAssertEqual(orphan.paths,[old]);XCTAssertEqual(orphan.safety,.review);XCTAssertFalse(orphan.automaticallySelected)
        let backups = try XCTUnwrap(items.first { $0.id == "claude-project-backups" })
        XCTAssertEqual(backups.paths,[oldBackup])
        XCTAssertFalse(AISessions.claudeCode(context(live:["88888888-8888-8888-8888-888888888888"])).contains { $0.id == "claude-orphans" })
    }
    func testOrphanWorkspaceStillKeepsRecentlyUpdatedChatState() throws {
        let base = "Library/Application Support/Cursor/User/workspaceStorage/"
        for (name,age) in [("old",40.0),("recent",5.0)] {
            let root = home+"/"+base+name
            let metadata = "{\"folder\":\""+URL(fileURLWithPath:home+"/missing-project").absoluteString+"\"}"
            try write(base+name+"/workspace.json",metadata,age:100)
            try write(base+name+"/state.vscdb",age:age)
            try touch(root,age:100)
        }
        let item = try XCTUnwrap(AISessions.editorWorkspaces(context()).first { $0.id == "cursor-orphan-workspaces" })
        XCTAssertEqual(item.paths,[home+"/"+base+"old"])
        XCTAssertEqual(item.safety,.review)
    }
}
