import XCTest
@testable import CleanKit
import AgentCore
@testable import thermo

final class CleanupIssueCLITests: XCTestCase {
    func testInvalidWhitelistListingRetainsRowsAndReportsRemovalDisabled() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let file = Whitelist.url(home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("~/keep\nrelative/path\n".utf8).write(to: file)
        var output = ""
        try CleanCommand(app: App(args: try Args(["--json"]))).whitelist([], home: home, write: { output = $0 })
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(result["removalAllowed"] as? Bool, false)
        XCTAssertEqual((result["rejected"] as? [[String: Any]])?.first?["line"] as? Int, 2)
        XCTAssertNotNil(result["issue"] as? String)
    }
    func testTimeoutAliasAndExclusiveBudgets() throws {
        XCTAssertEqual(try CleanCommand.budget(Args(["--timeout", "5"])), 5)
        XCTAssertEqual(try CleanCommand.budget(Args(["--budget", "2s"])), 2)
        XCTAssertThrowsError(try CleanCommand.budget(Args(["--timeout", "0"])))
        XCTAssertThrowsError(try CleanCommand.budget(Args(["--budget", "1", "--timeout", "2"])))
        XCTAssertTrue(try Args(["--exact"]).has("exact"))
    }
    func testTrashDryRunWithYesDoesNotRemoveAnything() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let trash = home + "/.Trash"
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        let kept = trash + "/keep"
        try Data("synthetic fixture".utf8).write(to: URL(fileURLWithPath: kept))
        let id = UUID().uuidString
        // The public cleaner records batches; a dry-run should load, review, and keep them.
        // An invalid id is rejected before looking at any user Trash.
        let command = CleanCommand(app: App(args: try Args(["--dry-run", "--yes", "--json"])))
        XCTAssertThrowsError(try command.emptyTrash(["../anything"], home: home))
        XCTAssertThrowsError(try command.emptyTrash([id], home: home))
        try TrashBatches.append(TrashBatch.Entry(original: home + "/old", destination: kept, identity: try XCTUnwrap(FileIdentity.of(kept)), bytes: 4096), id: id, home: home)
        var output = ""
        try command.emptyTrash([id], home: home, write: { output = $0 })
        let review = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(review["dryRun"] as? Bool, true)
        XCTAssertEqual((review["refusals"] as? [String: String])?.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept))
    }
    func testRestoreReviewsThenPutsTheBatchBack() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/.Trash", withIntermediateDirectories: true)
        let trashed = home + "/.Trash/old", original = home + "/old"
        try Data("synthetic fixture".utf8).write(to: URL(fileURLWithPath: trashed))
        let id = UUID().uuidString
        try TrashBatches.append(TrashBatch.Entry(original: original, destination: trashed, identity: try XCTUnwrap(FileIdentity.of(trashed)), bytes: 17), id: id, home: home)
        var output = ""
        try CleanCommand(app: App(args: try Args(["--dry-run", "--yes", "--json"]))).restoreBatch([id], home: home, write: { output = $0 })
        let review = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual(review["dryRun"] as? Bool, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed))
        try CleanCommand(app: App(args: try Args(["--yes", "--json"]))).restoreBatch([id], home: home, write: { output = $0 })
        let done = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual((done["items"] as? [[String: Any]])?.first?["status"] as? String, "restored")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed))
    }
}
