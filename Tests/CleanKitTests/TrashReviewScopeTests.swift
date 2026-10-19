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
    func testReviewedRestoreRecognizesTheSameObjectAlreadyAtItsOriginalPath() throws {
        let a = try append("a"), b = try append("b")
        _ = try TrashBatches.restore(id: id, home: home, reviewedDestinations: [b.destination])
        let review = try TrashBatches.restore(id: id, home: home, dryRun: true)
        XCTAssertEqual(review.items.first { $0.destination == b.destination }?.status, "alreadyRestored")
        let result = try TrashBatches.restore(id: id, home: home,
            reviewIdentity: review.reviewIdentity, reviewedDestinations: [a.destination])
        XCTAssertEqual(result.items.first { $0.destination == b.destination }?.status, "alreadyRestored")
        XCTAssertEqual(try String(contentsOfFile: b.original), "b")
        XCTAssertTrue(FS.exists(a.original))
        XCTAssertFalse(FS.exists(b.destination))
        let journal = try XCTUnwrap(OperationJournal.read(home: home).first {
            $0.items.contains { $0.target == a.original && $0.status == "done" }
        })
        XCTAssertEqual(journal.items.count, 1)
        XCTAssertEqual(journal.outcome, "succeeded")
    }

    func testMatchingInodeWithoutRecordedBirthProofIsNotAlreadyRestored() throws {
        let entry = try append("birth")
        try FileManager.default.moveItem(atPath: entry.destination, toPath: entry.original)
        var changed = try XCTUnwrap(TrashBatches.load(id, home: home).entries.first)
        changed.birthIdentity = "0:0:0"
        try TrashBatches.append(changed, id: id, home: home)
        let result = try TrashBatches.restore(id: id, home: home, dryRun: true)
        XCTAssertEqual(result.items.first?.status, "missing")
        XCTAssertEqual(try String(contentsOfFile: entry.original), "birth")
    }

    func testAReplacementAtOriginalPathDoesNotBecomeAnAlreadyRestoredItem() throws {
        let entry = try append("replacement")
        try FileManager.default.removeItem(atPath: entry.destination)
        try Data("new occupant".utf8).write(to: URL(fileURLWithPath: entry.original))
        let result = try TrashBatches.restore(id: id, home: home, dryRun: true)
        XCTAssertEqual(result.items.first?.status, "missing")
        XCTAssertEqual(try String(contentsOfFile: entry.original), "new occupant")
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
