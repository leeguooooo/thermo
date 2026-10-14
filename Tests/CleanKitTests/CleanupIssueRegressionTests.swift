import AgentCore
import Darwin
import XCTest
@testable import CleanKit

final class CleanupIssueRegressionTests: XCTestCase {
    var home = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-issue-" + UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: home) }
    func directory(_ path: String) throws { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
    func file(_ path: String, bytes: Int = 4096) throws {
        try directory((path as NSString).deletingLastPathComponent)
        try Data(repeating: 37, count: bytes).write(to: URL(fileURLWithPath: path))
    }
    func git(_ repo: String, _ args: [String]) throws -> String {
        let result = CommandRunner.run("/usr/bin/git", arguments: ["-C", repo] + args, timeout: 10)
        guard result.status == 0 else { throw NSError(domain: result.output, code: Int(result.status)) }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func worktree(_ name: String = "agent-fixture") throws -> (String, String) {
        let repo = home + "/repo", wt = repo + "/.claude/worktrees/" + name
        try directory(repo)
        _ = try git(repo, ["init"])
        _ = try git(repo, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture"])
        _ = try git(repo, ["worktree", "add", "-b", "fixture", wt])
        return (repo, wt)
    }
    func operations() -> RemovalOperations {
        RemovalOperations(trash: { path in
            let trash = self.home + "/.Trash"
            try self.directory(trash)
            let destination = URL(fileURLWithPath: trash).appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: URL(fileURLWithPath: path), to: destination)
            return destination
        }, remove: { try FileManager.default.removeItem(atPath: $0) })
    }
    func clean(_ item: CleanItem, mode: RemovalMode = .auto, ops: RemovalOperations? = nil, id: String? = nil) -> CleanResult {
        Cleaner.clean(item, mode: mode, guard: Guard(home: home), scannedAt: nil,
                      processTable: ProcessTable(entries: []), batchID: id, operations: ops ?? operations())
    }
    func testRecursiveFailureCountsRemovedChildrenAndKeepsResidual() throws {
        let path = home + "/Library/Caches/fixture"
        try file(path + "/large", bytes: 2 * 1024 * 1024)
        try file(path + "/.DS_Store", bytes: 6000)
        let item = CleanItem(id: "fixture", category: .aiCaches, title: "Fixture", safety: .safe, bytes: FS.size(path).bytes, paths: [path])
        var ops = operations()
        ops.remove = { path in
            try FileManager.default.removeItem(atPath: path + "/large")
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
        let result = clean(item, ops: ops)
        XCTAssertGreaterThanOrEqual(result.bytes, 2 * 1024 * 1024)
        XCTAssertEqual(result.partialRemoved, [path])
        XCTAssertEqual(result.outcome, "partial")
        XCTAssertNotNil(result.failed[path])
        XCTAssertTrue(FS.exists(path + "/.DS_Store"))
        XCTAssertTrue(result.removed.isEmpty)
    }
    func testReplacedDirectoryDuringFailureDoesNotClaimADeletionSize() throws {
        let path = home + "/Library/Caches/fixture"
        try file(path + "/data")
        let item = CleanItem(id: "fixture", category: .aiCaches, title: "Fixture", safety: .safe, bytes: 4096, paths: [path])
        var ops = operations()
        ops.remove = { path in
            try FileManager.default.moveItem(atPath: path, toPath: path + ".preserved")
            try self.file(path + "/replacement")
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
        let result = clean(item, ops: ops)
        XCTAssertEqual(result.bytes, 0)
        XCTAssertEqual(result.bytesIncomplete, true)
        XCTAssertEqual(result.outcome, "partial")
        XCTAssertTrue(FS.exists(path + "/replacement"))
    }
    func testTrashBatchDeletesOnlyOriginalRecordedEntries() throws {
        let path = home + "/Library/Caches/fixture"
        try file(path + "/data")
        let item = CleanItem(id: "fixture", category: .aiCaches, title: "Fixture", safety: .review, bytes: 4096, paths: [path])
        let result = clean(item)
        let batch = try TrashBatches.load(XCTUnwrap(result.trashBatchID), home: home)
        try file(home + "/.Trash/unrelated")
        let deleted = try TrashBatches.empty(batch.id, home: home)
        XCTAssertEqual(deleted.outcome, "success")
        XCTAssertFalse(FS.exists(batch.entries[0].destination))
        XCTAssertTrue(FS.exists(home + "/.Trash/unrelated"))
        XCTAssertNotNil(deleted.spaceObservation)
    }
    func testTrashReplacementAndRestoredItemsAreKept() throws {
        let path = home + "/Library/Caches/fixture"
        try file(path + "/data")
        let result = clean(CleanItem(id: "fixture", category: .aiCaches, title: "Fixture", safety: .review, bytes: 4096, paths: [path]))
        let batch = try TrashBatches.load(XCTUnwrap(result.trashBatchID), home: home)
        let destination = batch.entries[0].destination
        try FileManager.default.moveItem(atPath: destination, toPath: path)
        let absent = try TrashBatches.empty(batch.id, home: home)
        XCTAssertFalse(absent.failed.isEmpty)
        try file(destination + "/replacement")
        let replacement = try TrashBatches.empty(batch.id, home: home)
        XCTAssertFalse(replacement.failed.isEmpty)
        XCTAssertTrue(FS.exists(destination + "/replacement"))
        XCTAssertTrue(FS.exists(path + "/data"))
    }
    func testTrashManifestOutsidePathIsRejected() throws {
        let path = home + "/Library/Caches/important"
        try file(path)
        let entry = TrashBatch.Entry(original: path, destination: path, identity: try XCTUnwrap(FileIdentity.of(path)), bytes: 4096)
        let id = UUID().uuidString
        try TrashBatches.append(entry, id: id, home: home)
        let result = try TrashBatches.empty(id, home: home)
        XCTAssertFalse(result.failed.isEmpty)
        XCTAssertTrue(FS.exists(path))
    }
    func testWorktreeTrashUnregistersOnlyTargetAndPreservesRecoverableMetadata() throws {
        let (repo, path) = try worktree()
        let other = repo + "/.claude/worktrees/other"
        _ = try git(repo, ["worktree", "add", "--detach", other])
        let result = clean(CleanItem(id: "worktree/fixture", category: .agentWorktrees, title: "Fixture", safety: .review, bytes: 4096, paths: [path], group: repo))
        XCTAssertTrue(result.failed.isEmpty, "\(result.failed)")
        let list = try git(repo, ["worktree", "list", "--porcelain"])
        XCTAssertFalse(list.contains("worktree " + WorktreeCleanup.physical(path) + "\n"))
        XCTAssertTrue(list.contains("worktree " + WorktreeCleanup.physical(other)), "expected \(other) in \(list)")
        XCTAssertFalse(try git(repo, ["show-ref", "--verify", "refs/heads/fixture"]).isEmpty)
        let batch = try TrashBatches.load(XCTUnwrap(result.trashBatchID), home: home)
        let entry = try XCTUnwrap(batch.entries.first)
        let backup = try XCTUnwrap(entry.registrationBackup), metadata = try XCTUnwrap(entry.registrationOriginal)
        XCTAssertTrue(FS.exists(backup + "/HEAD"))
        // The retained registration can be restored with the checkout without touching another worktree.
        try directory((metadata as NSString).deletingLastPathComponent)
        try FileManager.default.moveItem(atPath: backup, toPath: metadata)
        try FileManager.default.moveItem(atPath: entry.destination, toPath: path)
        XCTAssertEqual(try git(path, ["status", "--porcelain"]), "")
        let restoredList = try git(repo, ["worktree", "list", "--porcelain"])
        XCTAssertTrue(restoredList.contains("worktree " + WorktreeCleanup.physical(path)), "expected \(path) in \(restoredList)")
    }
    func testDirtyAndLiveLockedWorktreesAreNeverRemoved() throws {
        let (repo, path) = try worktree()
        try file(path + "/unsaved.txt")
        var item = CleanItem(id: "worktree/fixture", category: .agentWorktrees, title: "Fixture", safety: .review, bytes: 4096, paths: [path], group: repo)
        XCTAssertFalse(clean(item, mode: .permanent).failed.isEmpty)
        XCTAssertTrue(FS.exists(path + "/unsaved.txt"))
        try FileManager.default.removeItem(atPath: path + "/unsaved.txt")
        _ = try git(repo, ["worktree", "lock", "--reason", "claude agent agent-fixture (pid \(getpid()))", path])
        item.blocked = nil
        XCTAssertFalse(clean(item).failed.isEmpty)
        XCTAssertTrue(FS.exists(path))
    }
    func testOwnedDeadLockIsUnlockedAndUnregistered() throws {
        let (repo, path) = try worktree()
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run(); child.waitUntilExit()
        _ = try git(repo, ["worktree", "lock", "--reason", "claude agent agent-fixture (pid \(child.processIdentifier), fixture)", path])
        let result = clean(CleanItem(id: "worktree/fixture", category: .agentWorktrees, title: "Fixture", safety: .review, bytes: 4096, paths: [path], group: repo))
        XCTAssertTrue(result.failed.isEmpty, "\(result.failed)")
        XCTAssertFalse(FS.exists(path))
        XCTAssertFalse(try git(repo, ["worktree", "list", "--porcelain"]).contains("worktree " + WorktreeCleanup.physical(path)))
    }
    func testUnknownLockIsKept() throws {
        let (repo, path) = try worktree()
        _ = try git(repo, ["worktree", "lock", "--reason", "portable disk", path])
        XCTAssertFalse(clean(CleanItem(id: "worktree/fixture", category: .agentWorktrees, title: "Fixture", safety: .review, bytes: 4096, paths: [path], group: repo)).failed.isEmpty)
        XCTAssertTrue(FS.exists(path))
    }
    func testLargeFlatTreeIsBoundedWithoutCancellingOtherItems() throws {
        let path = home + "/large"
        for n in 0..<150 { try file(path + "/f\(n)") }
        let bounded = FS.discoverySize(path, maxEntries: 32)
        XCTAssertTrue(bounded.incomplete)
        XCTAssertLessThanOrEqual(bounded.files, 32)
        let exact = FS.size(path)
        XCTAssertEqual(exact.files, 150)
        XCTAssertFalse(exact.incomplete)
    }
    func testScopeChangesAndPartialScansDoNotReplaceCompleteBaseline() throws {
        var a = ScanReport(items: [CleanItem(id: "p", category: .projects, title: "Fixture", safety: .review, bytes: 100)], denied: [], started: Date(timeIntervalSince1970: 100), duration: 1)
        a.categories = [.projects]; a.projectRoots = [home + "/p"]
        var b = a; b.started = Date(timeIntervalSince1970: 200); b.items[0].bytes = 300
        XCTAssertEqual(CleanScanHistory.compare(b, with: a)?.first?.changeBytes, 200)
        CleanScanHistory.record(&a, home: home)
        var partial = b; partial.cancelled = true
        CleanScanHistory.record(&partial, home: home)
        XCTAssertNil(partial.changesSince)
        CleanScanHistory.record(&b, home: home)
        XCTAssertEqual(b.changesSince, a.started)
        b.projectRoots = [home + "/other"]
        XCTAssertNil(CleanScanHistory.compare(b, with: a))
        b = a; b.started = Date(timeIntervalSince1970: 200); b.items[0].sizeIncomplete = true
        XCTAssertNil(CleanScanHistory.compare(b, with: a))
    }
    func testCacheTargetWithoutManifestIsDetectedAndProtectedFromAutomaticSelection() throws {
        let target = home + "/.cache/unified-target"
        try file(target + "/.rustc_info.json")
        try file(target + "/debug/binary", bytes: 2 * 1024 * 1024)
        var options = ScanOptions(); options.home = home; options.projectRoots = []; options.discoverProjectRoots = false; options.categories = [.projects]
        let scanner = DiskScanner(options: options); scanner.saveReport = false
        let report = scanner.scan()
        let item = try XCTUnwrap(report.items.first { $0.paths.contains(target) })
        XCTAssertFalse(item.automaticallySelected)
        let process = AgentProcess(pid: 555, name: "rustc", argv: ["rustc", "--out-dir", target + "/debug"], cwd: home + "/source")
        XCTAssertNotNil(Cleaner.refusal(item, mode: .auto, processes: ProcessTable(entries: [process])))
    }
    func testScratchpadMediaIsReviewAndNamed() throws {
        let path = home + "/scratch/project/session"
        try file(path + "/.DS_Store")
        let media = path + "/render.mp4"
        try file(media, bytes: 0)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: media)); try handle.truncate(atOffset: 60 * 1024 * 1024); try handle.close()
        let old = Date().addingTimeInterval(-3 * 86400)
        for p in [path + "/.DS_Store", media] { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: p) }
        let previous = FS.countsStatusChanges; FS.countsStatusChanges = false; defer { FS.countsStatusChanges = previous }
        var options = ScanOptions(); options.home = home
        let ctx = ScanContext(options: options, now: Date(), processes: ProcessTable(entries: []), agentDirs: [], liveClaudeSessions: [])
        let item = try XCTUnwrap(AITools.claudeScratch(ctx, scratchRoot: home + "/scratch").first)
        XCTAssertEqual(item.safety, .review)
        XCTAssertTrue(item.note?.contains("render.mp4") == true)
        XCTAssertFalse(item.automaticallySelected)
    }

    func testReplacementAtOriginalWorktreePathPreventsGitUnregistration() throws {
        let (repo, path) = try worktree()
        var ops = operations()
        let move = ops.trash
        ops.trash = { path in
            let destination = try move(path)
            try self.file(path + "/unrelated")
            return destination
        }
        let result = clean(CleanItem(id: "worktree/fixture", category: .agentWorktrees, title: "Fixture", safety: .review, bytes: 4096, paths: [path], group: repo), ops: ops)
        XCTAssertEqual(result.outcome, "partial")
        XCTAssertNotNil(result.failed["git/" + path])
        XCTAssertTrue(FS.exists(path + "/unrelated"))
        let batch = try TrashBatches.load(XCTUnwrap(result.trashBatchID), home: home)
        XCTAssertTrue(FS.exists(batch.entries[0].registrationBackup!))
    }

    func testLiveWorkingDirectoryAliasIsProtected() throws {
        let (_, path) = try worktree()
        let process = AgentProcess(pid: 100, name: "worker", cwd: WorktreeCleanup.physical(path))
        XCTAssertThrowsError(try WorktreeCleanup.registration(path, processes: ProcessTable(entries: [process])))
    }

    func testSizeHistoryRejectsCorruptNegativeCountersAndExactModeChanges() {
        var a = ScanReport(items: [CleanItem(id: "p", category: .projects, title: "Fixture", safety: .review, bytes: -1)], denied: [], started: Date(timeIntervalSince1970: 1), duration: 1)
        var b = a; b.started = Date(timeIntervalSince1970: 2); b.items[0].bytes = 20
        XCTAssertNil(CleanScanHistory.compare(b, with: a))
        a.items[0].bytes = 10; b.exactSizes = true
        XCTAssertNil(CleanScanHistory.compare(b, with: a))
    }

    func testLargeTrashBatchRecordsEachEntryWithoutRewritingPreviousEntries() throws {
        let paths = (0..<200).map { home + "/Library/Caches/fixture/f\($0)" }
        for path in paths { try file(path) }
        let result = clean(CleanItem(id: "fixture", category: .aiCaches, title: "Fixture", safety: .review, bytes: 200 * 4096, paths: paths))
        XCTAssertEqual(result.removed.count, 200)
        XCTAssertTrue(result.failed.isEmpty)
        let batch = try TrashBatches.load(XCTUnwrap(result.trashBatchID), home: home)
        XCTAssertEqual(batch.entries.count, 200)
        let data = try Data(contentsOf: TrashBatches.url(batch.id, home: home))
        XCTAssertEqual(data.split(separator: 10).count, 201)
    }

    func testTruncatedTrashJournalFailsClosed() throws {
        let path = home + "/.Trash/fixture"
        try file(path + "/keep")
        let id = UUID().uuidString
        try TrashBatches.append(TrashBatch.Entry(original: home + "/old", destination: path, identity: try XCTUnwrap(FileIdentity.of(path)), bytes: 4096), id: id, home: home)
        let handle = try FileHandle(forWritingTo: TrashBatches.url(id, home: home))
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{truncated".utf8)); try handle.close()
        XCTAssertThrowsError(try TrashBatches.empty(id, home: home))
        XCTAssertTrue(FS.exists(path + "/keep"))
    }

    func testOldMissingRegistrationsCanBeRepairedWithoutPruningUnrelatedOnes() throws {
        let (repo, path) = try worktree()
        let outside = repo + "/manual-checkout"
        _ = try git(repo, ["worktree", "add", "--detach", outside])
        try FileManager.default.moveItem(atPath: path, toPath: home + "/saved-checkout")
        try FileManager.default.removeItem(atPath: outside)
        let plan = try WorktreeRegistrationRepair.inspect(repo: repo, home: home)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(WorktreeCleanup.physical(plan[0].path), WorktreeCleanup.physical(path))
        let results = WorktreeRegistrationRepair.repair(repo: repo, entries: plan, home: home)
        XCTAssertNil(results.first?.error)
        XCTAssertTrue(FS.exists(results[0].backup! + "/HEAD"))
        let list = try git(repo, ["worktree", "list", "--porcelain"])
        XCTAssertFalse(list.contains("worktree " + WorktreeCleanup.physical(path)))
        XCTAssertTrue(list.contains("worktree " + WorktreeCleanup.physical(outside)))
        XCTAssertTrue(FS.exists(home + "/saved-checkout/.git"))
    }
    func testRegistrationRepairRefusesAWorktreeThatReappearedAfterReview() throws {
        let (repo, path) = try worktree()
        try FileManager.default.moveItem(atPath: path, toPath: home + "/saved-checkout")
        let plan = try WorktreeRegistrationRepair.inspect(repo: repo, home: home)
        try file(path + "/new-file")
        let results = WorktreeRegistrationRepair.repair(repo: repo, entries: plan, home: home)
        XCTAssertNotNil(results.first?.error)
        XCTAssertTrue(FS.exists(path + "/new-file"))
    }
    func testTrashBirthIdentityMismatchIsKept() throws {
        let path = home + "/.Trash/keep"
        try file(path)
        var entry = TrashBatch.Entry(original: home + "/old", destination: path, identity: try XCTUnwrap(FileIdentity.of(path)), bytes: 4096)
        entry.birthIdentity = "not-the-original-creation-identity"
        let id = UUID().uuidString
        try TrashBatches.append(entry, id: id, home: home)
        let result = try TrashBatches.empty(id, home: home)
        XCTAssertFalse(result.failed.isEmpty)
        XCTAssertTrue(FS.exists(path))
    }
}
