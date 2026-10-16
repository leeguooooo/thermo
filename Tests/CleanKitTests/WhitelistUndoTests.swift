import XCTest
@testable import CleanKit

final class WhitelistUndoTests: XCTestCase {
    var home = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("whitelist-undo-" + UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func testUndoRemovesOnlyNewEntriesAndCannotBeReplayed() throws {
        try Whitelist.add([home + "/existing"], home: home)
        let file = Whitelist.url(home: home)
        var text = try String(contentsOf: file, encoding: .utf8); text += "# keep this comment\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let change = try Whitelist.addWithUndo([home + "/existing", home + "/new", home + "/new"], home: home)
        XCTAssertEqual(change.added, [home + "/new"])
        let undo = try XCTUnwrap(change.undo)
        XCTAssertEqual(try Whitelist.undoAddition(undo), change.added)
        XCTAssertEqual(try Whitelist.loadForRemoval(home: home).entries, [home + "/existing"])
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("# keep this comment"))
        XCTAssertThrowsError(try Whitelist.undoAddition(undo))
    }
    func testAlreadyProtectedEntryHasNoUndo() throws {
        try Whitelist.add([home + "/existing"], home: home)
        let change = try Whitelist.addWithUndo([home + "/existing"], home: home)
        XCTAssertTrue(change.added.isEmpty); XCTAssertNil(change.undo)
        XCTAssertTrue(try Whitelist.loadForRemoval(home: home).protects(home + "/existing"))
    }
    func testExternalCommentEditRefusesUndoWithoutOverwriting() throws {
        let undo = try XCTUnwrap(Whitelist.addWithUndo([home + "/new"], home: home).undo)
        let file = Whitelist.url(home: home)
        let edited = try String(contentsOf: file, encoding: .utf8) + "# external edit\n"
        try edited.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Whitelist.undoAddition(undo))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), edited)
    }
    func testAnotherWriterAdditionRefusesUndoAndPreservesBoth() throws {
        let undo = try XCTUnwrap(Whitelist.addWithUndo([home + "/new"], home: home).undo)
        try Whitelist.add([home + "/other-writer"], home: home)
        XCTAssertThrowsError(try Whitelist.undoAddition(undo))
        XCTAssertEqual(Set(try Whitelist.loadForRemoval(home: home).entries), [home + "/new", home + "/other-writer"])
    }
    func testRemoveAndReaddSameRuleDoesNotReuseOldUndo() throws {
        let undo = try XCTUnwrap(Whitelist.addWithUndo([home + "/new"], home: home).undo)
        try Whitelist.remove([home + "/new"], home: home)
        try Whitelist.add([home + "/new"], home: home)
        XCTAssertThrowsError(try Whitelist.undoAddition(undo))
        XCTAssertTrue(try Whitelist.loadForRemoval(home: home).protects(home + "/new"))
    }
}
