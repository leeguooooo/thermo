import XCTest
@testable import CleanKit
@testable import SpaceFeature

final class SpaceConfirmationReviewTests:XCTestCase {
    @MainActor func testChangedSpaceSelectionCannotExpandFrozenConfirmation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("Downloads/a"), b = root.appendingPathComponent("Downloads/b")
        for path in [a,b] { try Data("own".utf8).write(to: path) }
        let model = SpaceLensModel(services:FixtureSpaceServices(),root: root.path, cache: root.appendingPathComponent("cache"), remove: { _, _, _, _, _, _ in XCTFail("Changed confirmation must not execute"); return .init(id: "fixture", trashed: true) })
        model.toggle(a.path, bytes: 3); let snapshot = try XCTUnwrap(model.removalReview())
        model.toggle(b.path, bytes: 3); model.trash(review: snapshot)
        XCTAssertFalse(model.working); XCTAssertEqual(model.basket.count, 2); XCTAssertEqual(snapshot.selection.keys.sorted(), [a.path]); XCTAssertTrue(model.outcomeIsWarning)
    }
}
