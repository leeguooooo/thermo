@testable import CleanKit
import AgentCore
import Foundation
import XCTest

final class TrashReviewScopeTests: XCTestCase {
    var home = "", id = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        id = UUID().uuidString
        for dir in [".Trash", "Downloads"] { try FileManager.default.createDirectory(atPath: home + "/" + dir, withIntermediateDirectories: true) }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func append(_ name: String) throws -> TrashBatch.Entry {
        let path = home + "/.Trash/" + name; try Data(name.utf8).write(to: URL(fileURLWithPath: path))
        let entry = TrashBatch.Entry(original: home + "/Downloads/" + name, destination: path, identity: try XCTUnwrap(FileIdentity.of(path)), bytes: 1)
        try TrashBatches.append(entry, id: id, home: home); return entry
    }
    func testAppendedEntryRejectsReviewedRestoreBeforeAnyMove() throws {
        let a = try append("a"), review = try TrashBatches.restore(id: id, home: home, dryRun: true), b = try append("b")
        XCTAssertThrowsError(try TrashBatches.restore(id: id, home: home, reviewIdentity: review.reviewIdentity, reviewedDestinations: [a.destination]))
        for item in [a,b] { XCTAssertTrue(FS.exists(item.destination)); XCTAssertFalse(FS.exists(item.original)) }
    }
    func testPreviouslyConflictingItemCannotBecomeAnUnreviewedRestore() throws {
        let a = try append("a"), b = try append("b"); try Data("new occupant".utf8).write(to: URL(fileURLWithPath: b.original))
        let review = try TrashBatches.restore(id: id, home: home, dryRun: true)
        XCTAssertEqual(review.items.filter { $0.status == "restored" }.map(\.destination), [a.destination])
        try FileManager.default.removeItem(atPath: b.original)
        let result = try TrashBatches.restore(id: id, home: home, reviewIdentity: review.reviewIdentity, reviewedDestinations: [a.destination])
        XCTAssertTrue(FS.exists(a.original)); XCTAssertTrue(FS.exists(b.destination)); XCTAssertFalse(FS.exists(b.original))
        XCTAssertEqual(result.items.first { $0.destination == b.destination }?.status, "skipped")
    }
    func testChangedBatchRejectsPermanentRemovalBeforeDeletion() throws {
        let a = try append("a"), batch = try TrashBatches.load(id, home: home), token = try TrashBatches.reviewIdentity(batch), b = try append("b")
        XCTAssertThrowsError(try TrashBatches.empty(id, home: home, reviewIdentity: token, reviewedDestinations: [a.destination]))
        XCTAssertTrue(FS.exists(a.destination)); XCTAssertTrue(FS.exists(b.destination))
    }
    func testLegacyRestoreJSONHasNoReviewProof() throws {
        let value = try JSONDecoder().decode(TrashRestore.self, from: Data(#"{"id":"fixture","dryRun":true,"items":[]}"#.utf8))
        XCTAssertNil(value.reviewIdentity)
    }
}
