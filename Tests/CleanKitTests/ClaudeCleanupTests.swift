import XCTest
import Darwin
import AgentCore
@testable import CleanKit

final class ClaudeCleanupTests: XCTestCase {
    private var home: String!
    override func setUpWithError() throws {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("claude-reset-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let resolved = try XCTUnwrap(realpath(url.path, nil))
        defer { free(resolved) }
        home = String(cString: resolved)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    private func service(limit: Int = 20_000) -> ClaudeCleanup {
        ClaudeCleanup(home: home, processes: { ProcessTable(entries: []) }, liveSessionCheck: { _ in false }, entryLimit: limit)
    }
    private func write(_ rel: String, _ value: String = "fixture-secret") throws {
        let url = URL(fileURLWithPath: home).appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }
    private func selection(_ target: ClaudeResetTarget, _ cleaner: ClaudeCleanup) throws -> ClaudeResetCandidate {
        try XCTUnwrap(cleaner.scan().first { $0.target == target })
    }
    func testAllowlistRoundTripAndPrivateManifest() throws {
        try write(".claude/.credentials.json")
        try write(".claude/settings.json", "settings")
        let cleaner = service()
        XCTAssertEqual(cleaner.scan().count, ClaudeResetTarget.allCases.count)
        let candidate = try selection(.credentials, cleaner)
        XCTAssertEqual(candidate.status, .available, candidate.reason ?? "")
        XCTAssertEqual(candidate.bytes, 14)
        let snapshot = try XCTUnwrap(candidate.snapshot, candidate.reason ?? "")
        XCTAssertFalse(snapshot.contains("fixture-secret"))
        let result = cleaner.reset([candidate])
        XCTAssertTrue(result.failed.isEmpty, "\(result.failed)")
        XCTAssertEqual(result.succeeded, [.credentials])
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.claude/settings.json"))
        let batch = try XCTUnwrap(result.batch)
        XCTAssertEqual(cleaner.batches().map(\.id), [batch.id])
        let folder = try XCTUnwrap(cleaner.backupURL(batchID: batch.id))
        let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        let manifestMode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("manifest.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(manifestMode?.intValue, 0o600)
        let restored = cleaner.restore(batchID: batch.id)
        XCTAssertTrue(restored.failed.isEmpty, "\(restored.failed)")
        XCTAssertEqual(restored.succeeded, [.credentials])
        XCTAssertEqual(try String(contentsOfFile: candidate.path), "fixture-secret")
    }
    func testChangesAndOverlappingSelectionsAreRefused() throws {
        try write(".claude/settings.json")
        let cleaner = service()
        let old = try selection(.settings, cleaner)
        try write(".claude/settings.json", "new-value-with-different-size")
        XCTAssertTrue(cleaner.reset([old]).succeeded.isEmpty)
        let full = try selection(.codeData, cleaner)
        let child = try selection(.settings, cleaner)
        XCTAssertTrue(cleaner.reset([full, child]).succeeded.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
    }
    func testRestoreNeverOverwritesNewData() throws {
        try write(".claude.json")
        let cleaner = service()
        let reset = cleaner.reset([try selection(.globalConfig, cleaner)])
        let batch = try XCTUnwrap(reset.batch)
        try write(".claude.json", "new account")
        let result = cleaner.restore(batchID: batch.id)
        XCTAssertTrue(result.succeeded.isEmpty)
        XCTAssertNotNil(result.failed[ClaudeResetTarget.globalConfig.rawValue])
        XCTAssertEqual(try String(contentsOfFile: home + "/.claude.json"), "new account")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleaner.backupURL(batchID: batch.id)!.appendingPathComponent("globalConfig").path))
    }
    func testSymlinkComponentsBlockedButDescendantLinksAreMovedWithoutFollowing() throws {
        try write("outside/precious", "keep")
        try FileManager.default.createSymbolicLink(atPath: home + "/.claude", withDestinationPath: home + "/outside")
        let cleaner = service()
        XCTAssertEqual(try selection(.codeData, cleaner).status, .blocked)
        try FileManager.default.removeItem(atPath: home + "/.claude")
        try write(".claude/settings.json")
        try FileManager.default.createSymbolicLink(atPath: home + "/.claude/link", withDestinationPath: home + "/outside")
        let result = cleaner.reset([try selection(.codeData, cleaner)])
        XCTAssertEqual(result.succeeded, [.codeData])
        XCTAssertEqual(try String(contentsOfFile: home + "/outside/precious"), "keep")
        XCTAssertTrue(cleaner.restore(batchID: try XCTUnwrap(result.batch).id).failed.isEmpty)
    }
    func testActiveProcessAndExecutionRecheck() throws {
        try write(".claude/settings.json")
        var running = false
        let cleaner = ClaudeCleanup(home: home, processes: {
            ProcessTable(entries: running ? [AgentProcess(pid: 123, name: "Claude")] : [])
        }, liveSessionCheck: { _ in false })
        let candidate = try selection(.settings, cleaner)
        running = true
        XCTAssertEqual(try selection(.settings, cleaner).status, .blocked)
        XCTAssertTrue(cleaner.reset([candidate]).succeeded.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
    }
    func testNativeNodeAndDesktopHelperProcessesBlockReset() throws {
        try write(".claude.json")
        let running = [
            AgentProcess(pid: 123, name: "2.1.7", executable: "/Users/fixture/.local/share/claude/versions/2.1.7"),
            AgentProcess(pid: 124, name: "node", argv: ["node", "/usr/local/lib/node_modules/claude-code/cli.js"]),
            AgentProcess(pid: 125, name: "Helper", executable: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper")
        ]
        for process in running {
            let cleaner = ClaudeCleanup(home: home, processes: { ProcessTable(entries: [process]) }, liveSessionCheck: { _ in false })
            XCTAssertEqual(try selection(.globalConfig, cleaner).status, .blocked)
        }
    }
    func testSessionLinkBlocksBeforeReadingMetadata() throws {
        try write(".claude.json")
        try write("unrelated.json")
        try FileManager.default.createDirectory(atPath: home + "/.claude/sessions", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/.claude/sessions/123.json", withDestinationPath: home + "/unrelated.json")
        var consulted = false
        let cleaner = ClaudeCleanup(home: home, processes: { ProcessTable(entries: []) }, liveSessionCheck: { _ in consulted = true; return false })
        XCTAssertEqual(try selection(.globalConfig, cleaner).status, .blocked)
        XCTAssertFalse(consulted)
    }
    func testBoundedInventoryAndPartialMoveFailure() throws {
        try write(".claude/settings.json")
        try write(".claude/.credentials.json")
        XCTAssertEqual(try selection(.codeData, service(limit: 1)).status, .blocked)
        let cleaner = ClaudeCleanup(home: home, processes: { ProcessTable(entries: []) }, liveSessionCheck: { _ in false }, move: { from, to in
            if from.lastPathComponent == "settings.json" { throw NSError(domain: "fixture", code: 1) }
            try FileManager.default.moveItem(at: from, to: to)
        })
        let result = cleaner.reset([try selection(.credentials, cleaner), try selection(.settings, cleaner)])
        XCTAssertEqual(result.succeeded, [.credentials])
        XCTAssertNotNil(result.failed["settings"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.claude/settings.json"))
        XCTAssertTrue(cleaner.restore(batchID: try XCTUnwrap(result.batch).id).succeeded.contains(.credentials))
    }
    func testBackupAncestorSymlinkAndInvalidBatchIDRejected() throws {
        try write(".claude.json")
        try write("elsewhere/keep")
        try FileManager.default.createDirectory(atPath: home + "/Library/Application Support", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/Library/Application Support/Thermo", withDestinationPath: home + "/elsewhere")
        let cleaner = service()
        XCTAssertTrue(cleaner.reset([try selection(.globalConfig, cleaner)]).succeeded.isEmpty)
        XCTAssertNil(cleaner.backupURL(batchID: "../elsewhere"))
        XCTAssertThrowsError(try cleaner.loadBatch(id: "../elsewhere"))
    }
}
