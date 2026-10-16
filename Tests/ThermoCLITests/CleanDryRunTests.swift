import XCTest
import CleanKit
@testable import thermo

final class CleanDryRunTests: XCTestCase {
    func testCleanupScanUsesOnlyKnownSelectionCategories() {
        XCTAssertEqual(CleanCommand.cleanupCategories(for: ["projects"]), [.projects])
        XCTAssertEqual(CleanCommand.cleanupCategories(for: ["project/repo-target"]), [.projects])
        XCTAssertEqual(CleanCommand.cleanupCategories(for: ["simulator-unavailable", "xcode-derived-data"]), [.xcode])
        XCTAssertNil(CleanCommand.cleanupCategories(for: ["safe"]))
        XCTAssertNil(CleanCommand.cleanupCategories(for: ["unknown-id"]))
    }

    func testItemSelectionsNarrowTheScanAndGroupsDoNot() {
        XCTAssertEqual(CleanCommand.itemIDs(in: ["claude-scratchpads", "codex-sessions/x#a,b"]), ["claude-scratchpads", "codex-sessions/x"])
        XCTAssertNil(CleanCommand.itemIDs(in: ["claude-scratchpads", "safe"]))
        XCTAssertNil(CleanCommand.itemIDs(in: ["projects"]))
        XCTAssertNil(CleanCommand.itemIDs(in: ["codex-*"]))
    }

    func testCancelledPreviewWithNoFindingsIsExplicitlyIncomplete() throws {
        let report = ScanReport(items: [], denied: [], started: Date(), duration: 1, cancelled: true)
        let command = CleanCommand(app: App(args: try Args(["--dry-run", "--json"])))
        var output = ""
        try command.execute(report: report, picked: [], mode: .auto, write: { output = $0 })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(json["scanCancelled"] as? Bool, true)
        XCTAssertEqual((json["items"] as? [Any])?.count, 0)
    }

    func testDryRunWithYesNeitherDeletesNorRunsCommands() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/dev.thermo-tests/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("keep")
        let sentinel = root.appendingPathComponent("command-must-not-run")
        try Data("must survive".utf8).write(to: file)
        let item = CleanItem(id: "fixture", category: .system, title: "Fixture", safety: .safe, bytes: 100,
                             paths: [file.path], commands: [["/usr/bin/touch", sentinel.path]])
        let report = ScanReport(items: [item], denied: [], started: Date(), duration: 1)
        let command = CleanCommand(app: App(args: try Args(["clean", "run", "safe", "--dry-run", "--yes", "--json"])))
        var output = ""
        try command.execute(report: report, picked: [item], mode: .permanent, write: { output = $0 })
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(json["dryRun"] as? Bool, true)
        XCTAssertEqual((json["items"] as? [[String: Any]])?.first?["action"] as? String, "tool-removal")
    }
    func testTrashOnlyPreviewSkipsPermanentToolCommands() throws {
        let item = CleanItem(id: "fixture", category: .xcode, title: "Fixture", safety: .review, bytes: 100,
                             commands: [["/usr/bin/true"]])
        let report = ScanReport(items: [item], denied: [], started: Date(), duration: 1)
        let command = CleanCommand(app: App(args: try Args(["--dry-run", "--yes", "--json"])))
        var output = ""
        try command.execute(report: report, picked: [item], mode: .trash, write: { output = $0 })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual((json["items"] as? [Any])?.count, 0)
        XCTAssertEqual((json["skipped"] as? [Any])?.count, 1)
    }
}

extension CleanDryRunTests {
    func testConversationAgeNeedsAnExplicitOption() throws {
        let defaults = CleanCommand(app:App(args:try Args(["clean","sessions"])))
        XCTAssertNil(try defaults.options().sessionRetentionDays)
        let explicit = CleanCommand(app:App(args:try Args(["clean","sessions","--older-than","90d"])))
        XCTAssertEqual(try explicit.options().sessionRetentionDays,90)
    }
    func testSessionOnlyRunWithoutAgeRefusesBeforeScanning() throws {
        let command = CleanCommand(app:App(args:try Args(["clean","run","sessions","--dry-run","--yes"])))
        XCTAssertThrowsError(try command.clean(["sessions"])) { XCTAssertTrue(String(describing:$0).contains("--older-than")) }
        XCTAssertThrowsError(try command.clean(["codex-sessions/fixture"])) { XCTAssertTrue(String(describing:$0).contains("--older-than")) }
    }
    func testSessionAliasesAndIdsUseTheSameNarrowScope() {
        XCTAssertEqual(CleanCommand.cleanupCategories(for:["sessions"]),[.aiSessions])
        XCTAssertEqual(CleanCommand.cleanupCategories(for:["codex-sessions/fixture#a"]),[.aiSessions])
        XCTAssertEqual(CleanCommand.cleanupCategories(for:["roo-code-tasks/code"]),[.aiSessions])
        XCTAssertEqual(CleanCommand.cleanupCategories(for:["kilo-code-tasks/code"]),[.aiSessions])
        XCTAssertNil(CleanCommand.itemIDs(in:["sessions"]))
        XCTAssertEqual(CleanCommand.normalizedSelectors(["sessions","worktrees","models"]),["ai-sessions","agent-worktrees","ai-models"])
    }
}
