import XCTest
import CleanKit
import ThermoL10n
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
    func testDryRunNamesTheToolCommandAndRunsNothing() throws {
        // The CLI pins English (main.swift); the test process follows the system language.
        let language = L10n.override
        L10n.override = .english
        defer { L10n.override = language }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-dry-native-" + UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent(".npm/_cacache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("blob".utf8).write(to: cache.appendingPathComponent("blob"))
        let sentinel = root.appendingPathComponent("command-must-not-run")
        let program = root.appendingPathComponent("npm")
        try Data("#!/bin/sh\ntouch '\(sentinel.path)'\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        var item = CleanItem(id: "fixture", category: .devCaches, title: "npm cache", safety: .safe, bytes: 100, paths: [cache.path])
        item.native = NativeClean(tool: "npm", display: "npm cache clean --force",
                                  runs: [.init(folder: cache.path, argv: [program.path, "cache", "clean", "--force"])])
        let report = ScanReport(items: [item], denied: [], started: Date(), duration: 1)
        for flags in [["--dry-run", "--yes"], ["--dry-run", "--yes", "--json"]] {
            var output = ""
            try CleanCommand(app: App(args: try Args(["clean", "run", "fixture"] + flags)))
                .execute(report: report, picked: [item], mode: .auto, write: { output += $0 + "\n" })
            XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
            if flags.contains("--json") {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
                let first = try XCTUnwrap((json["items"] as? [[String: Any]])?.first)
                XCTAssertEqual(first["action"] as? String, "tool-clean")
                XCTAssertEqual(first["commands"] as? [String], [program.path + " cache clean --force"])
            } else {
                XCTAssertTrue(output.contains("runs `npm cache clean --force`"), output)
                XCTAssertTrue(output.contains(program.path + " cache clean --force"), output)
            }
        }
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
