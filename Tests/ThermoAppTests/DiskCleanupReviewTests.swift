import CleanKit
import XCTest
@testable import ThermoApp

final class DiskCleanupReviewTests: XCTestCase {
    func model() -> (DiskModel, CleanItem, CleanItem) {
        let a = CleanItem(id: "a", category: .devCaches, title: "Reviewed A", safety: .review, bytes: 100, paths: ["/fixture/a"])
        let b = CleanItem(id: "b", category: .devCaches, title: "Later B", safety: .review, bytes: 200, paths: ["/fixture/b"])
        let model = DiskModel(report: .init(items: [a,b], denied: [], started: Date(timeIntervalSince1970: 100), duration: 0))
        model.selected = [a.id]; return (model,a,b)
    }
    func testConfirmationContentDoesNotFollowLaterSelection() throws {
        let (model,a,b) = model()
        let review = try XCTUnwrap(model.cleanupReview())
        let confirmation = DiskCleanConfirmation(review: review, confirm: {}, cancel: {})
        let lines = model.planLines
        model.selected = [b.id]
        XCTAssertTrue(lines.contains { $0.contains(a.title) })
        XCTAssertEqual(confirmation.review.lines, lines, "A confirmation must keep the reviewed list rather than follow live selection")
    }
    func testChangedSelectionCannotExecuteAnOldReview() throws {
        let (model,_,b) = model(), review = try XCTUnwrap(model.cleanupReview())
        model.selected = [b.id]; model.lastResult = "earlier success"
        XCTAssertFalse(model.isCurrentCleanupReview(review))
        model.clean(review: review)
        XCTAssertNotNil(model.error); XCTAssertNil(model.lastResult); XCTAssertFalse(model.cleaning)
    }
    func testSameItemsFromAnotherScanRequireFreshReview() throws {
        let (model,a,b) = model(), review = try XCTUnwrap(model.cleanupReview())
        model.acceptScan(.init(items: [a,b], denied: [], started: Date(timeIntervalSince1970: 200), duration: 0))
        XCTAssertFalse(model.isCurrentCleanupReview(review))
        model.clean(review: review)
        XCTAssertNotNil(model.error); XCTAssertFalse(model.cleaning)
    }
    func testChangedCommandOrPartCannotReuseReviewEvenWithSameIDAndScanTime() throws {
        let (model,a,b) = model(), review = try XCTUnwrap(model.cleanupReview())
        var changed = a
        changed.paths = ["/fixture/replaced"]
        changed.commands = [["/usr/bin/true"]]
        model.acceptScan(.init(items: [changed,b], denied: [], started: review.scannedAt!, duration: 0))
        XCTAssertFalse(model.isCurrentCleanupReview(review))
        model.clean(review: review)
        XCTAssertNotNil(model.error); XCTAssertFalse(model.cleaning)
    }
    func testUnrelatedProgressDoesNotInvalidateReviewedTargets() throws {
        let (model,_,_) = model(), review = try XCTUnwrap(model.cleanupReview())
        model.error = "other inspection message"; model.lastResult = "earlier result"
        XCTAssertTrue(model.isCurrentCleanupReview(review))
        XCTAssertEqual(review.bytes, 100)
        model.selected = []
        XCTAssertNil(model.cleanupReview())
    }

}
