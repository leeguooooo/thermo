import XCTest
@testable import CleanKit
import AgentCore
@testable import thermo

final class CleanupIssueCLITests: XCTestCase {
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
}
