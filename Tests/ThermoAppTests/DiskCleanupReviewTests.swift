import CleanKit
import AgentCore
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

final class CleanDuringScanTests: XCTestCase {
    private func item(_ id: String) -> CleanItem {
        CleanItem(id: id, category: .devCaches, title: id, safety: .safe, bytes: 10, paths: ["/nonexistent/thermo-fixture/" + id])
    }
    @MainActor func testItemCleanedMidScanDoesNotReturnWithTheFinalReport() async throws {
        let a = item("a"), b = item("b"), release = DispatchSemaphore(value: 0), streamed = expectation(description: "streamed")
        let io = DiskScanIO(options: { _, _, _ in ScanOptions() }, cached: { _, _ in nil }, scan: { _, _, _, found in
            found([a]); DispatchQueue.main.async { streamed.fulfill() }
            release.wait()
            return ScanReport(items: [a, b], denied: [], started: Date(), duration: 1)
        })
        let model = DiskModel(scanIO: io, requestNotifications: {})
        // A scratch home: the failed cleanup is logged there, not in the user's operation history.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-clean-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        model.cleanGuard = Guard(home: home)
        model.scan()
        await fulfillment(of: [streamed], timeout: 5)
        for _ in 0..<100 where model.report?.items.isEmpty != false { try await Task.sleep(nanoseconds: 10_000_000) }
        let review = try XCTUnwrap(model.cleanupReview(of: a))
        XCTAssertTrue(model.scanning)
        model.clean(review: review)
        XCTAssertTrue(model.cleaning, "Cleaning must start while the scan is running")
        for _ in 0..<500 where model.cleaning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.cleaning, "Cleaning must not wait behind the scan")
        release.signal()
        for _ in 0..<500 where model.scanning { try await Task.sleep(nanoseconds: 10_000_000) }
        // The fixture path is missing, so the cleaned item survives only as a blocked remainder,
        // not as the scanner's fresh, cleanable copy.
        XCTAssertEqual(model.report?.items.first { $0.id == "a" }?.cleanable, false)
        XCTAssertEqual(model.report?.items.first { $0.id == "b" }?.cleanable, true)
    }
    func testReviewedSelectionStaysValidWhenNewFindingsArrive() throws {
        let a = item("a"), model = DiskModel(report: ScanReport(items: [a], denied: [], started: Date(), duration: 1))
        model.selected = ["a"]
        let single = try XCTUnwrap(model.cleanupReview(of: a))
        model.selected = []
        XCTAssertTrue(model.isCurrentCleanupReview(single), "A row's clean does not depend on what is ticked")
    }
}
