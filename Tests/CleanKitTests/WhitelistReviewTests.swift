import XCTest
@testable import CleanKit

final class WhitelistReviewTests: XCTestCase {
    var home = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("whitelist-review-" + UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func testOpeningAbsentListCreatesNoConfigurationDirectory() throws {
        let review = try Whitelist.review(home: home)
        XCTAssertTrue(review.value.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/Library"))
    }
    func testReviewedRemovalKeepsOtherRulesAndCannotReuseOldSnapshot() throws {
        try Whitelist.add([home + "/one", home + "/two"], home: home)
        let review = try Whitelist.review(home: home)
        XCTAssertEqual(try Whitelist.removeReviewed(home + "/one", review: review), [home + "/one"])
        XCTAssertEqual(try Whitelist.loadForRemoval(home: home).entries, [home + "/two"])
        XCTAssertThrowsError(try Whitelist.removeReviewed(home + "/two", review: review))
        XCTAssertEqual(try Whitelist.loadForRemoval(home: home).entries, [home + "/two"])
    }
    func testExternalEditRefusesReviewedRemovalAndPreservesExactText() throws {
        try Whitelist.add([home + "/one"], home: home)
        let review = try Whitelist.review(home: home), file = Whitelist.url(home: home)
        let text = try String(contentsOf: file, encoding: .utf8) + "# later edit\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Whitelist.removeReviewed(home + "/one", review: review))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
    }
    func testInvalidRowsRemainInspectableAndBlockRemoval() throws {
        try Whitelist.add([home + "/one"], home: home)
        let file = Whitelist.url(home: home), text = try String(contentsOf: file, encoding: .utf8) + "relative/rule\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let review = try Whitelist.review(home: home)
        XCTAssertEqual(review.value.rejected.count, 1)
        XCTAssertThrowsError(try Whitelist.removeReviewed(home + "/one", review: review))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
    }
    func testPathChangeDuringReviewIsRejected() throws {
        try Whitelist.add([home + "/one"], home: home)
        XCTAssertThrowsError(try Whitelist.review(home: home, afterRead: {
            try Data("# replaced\n".utf8).write(to: Whitelist.url(home: self.home), options: .atomic)
        }))
    }
    func testUnreviewedEntryCannotExpandRemovalScope() throws {
        try Whitelist.add([home + "/one"], home: home)
        let review = try Whitelist.review(home: home)
        XCTAssertThrowsError(try Whitelist.removeReviewed(home + "/other", review: review))
        XCTAssertEqual(try Whitelist.loadForRemoval(home: home).entries, [home + "/one"])
    }
}
