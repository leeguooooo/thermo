@testable import CleanKit
@testable import ThermoApp
import AgentCore
import XCTest

final class ConfirmationReviewTests: XCTestCase {
    func record(_ id: String = UUID().uuidString) -> OperationRecord {
        .init(feature: "fixture", action: "remove", items: [.init(target: "/old-record", status: "done")], undo: .init(kind: "trashBatch", ref: id))
    }
    func review(_ id: String) -> TrashRestore {
        .init(id: id, dryRun: true, items: [.init(original: "/actual-preview", destination: "/trash/a", bytes: 1, status: "restored")], reviewIdentity: "fixture")
    }
    @MainActor func testRestoreReviewCancellationRetainsOnePhysicalReaderAndQueuesLatest() async throws {
        let a = record(), b = record(), began = expectation(description: "first read"), release = DispatchSemaphore(value: 0), calls = Calls()
        defer { release.signal() }
        let model = HistoryModel(reviewBatch: { id in
            if calls.next() == 1 { began.fulfill(); _ = release.wait(timeout: .now() + 5) }
            return .init(id: id, dryRun: true, items: [.init(original: "/actual-preview", destination: "/trash/a", bytes: 1, status: "restored")], reviewIdentity: "fixture")
        })
        model.prepareRestore(a); await fulfillment(of: [began], timeout: 2)
        model.cancelRestoreReview(for: a.undo!.ref)
        for _ in 0..<100 { model.prepareRestore(b) }
        model.cancelRestoreReview(for: a.undo!.ref)
        XCTAssertEqual(calls.count, 1); XCTAssertTrue(model.reviewingRestore)
        release.signal()
        for _ in 0..<200 where model.reviewingRestore { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(calls.count, 2); XCTAssertEqual(model.restoreReview?.id, b.undo?.ref)
        XCTAssertEqual(model.restoreReview?.items.first?.original, "/actual-preview")
    }
    @MainActor func testFailedPreviewAndMissingProofNeverStartRestore() async throws {
        let entry = record()
        let model = HistoryModel(reviewBatch: { _ in throw NSError(domain: "fixture", code: 1) }, restoreBatch: { _, _ in XCTFail("No confirmed review"); throw NSError(domain: "fixture", code: 2) })
        model.prepareRestore(entry)
        for _ in 0..<100 where model.reviewingRestore { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(model.restoreReviewIssue); XCTAssertNil(model.restoreReview)
        var unproved = review(entry.undo!.ref); unproved.reviewIdentity = nil
        model.restore(entry, review: unproved)
        XCTAssertFalse(model.busy); XCTAssertNotNil(model.notice)
    }
    @MainActor func testChangedSpaceSelectionCannotExpandFrozenConfirmation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("Downloads/a"), b = root.appendingPathComponent("Downloads/b")
        for path in [a,b] { try Data("own".utf8).write(to: path) }
        let model = SpaceLensModel(root: root.path, cache: root.appendingPathComponent("cache"), remove: { _, _, _, _, _, _ in XCTFail("Changed confirmation must not execute"); return .init(id: "fixture", trashed: true) })
        model.toggle(a.path, bytes: 3); let snapshot = try XCTUnwrap(model.removalReview())
        model.toggle(b.path, bytes: 3); model.trash(review: snapshot)
        XCTAssertFalse(model.working); XCTAssertEqual(model.basket.count, 2); XCTAssertEqual(snapshot.selection.keys.sorted(), [a.path]); XCTAssertTrue(model.outcomeIsWarning)
    }
    @MainActor func testPermanentToolConfirmationWarnsRegardlessOfSafetyTag() {
        for safety in [Safety.safe, .review, .risky] {
            let item = CleanItem(id: "fixture", category: .xcode, title: "fixture", safety: safety, bytes: 1,
                                 commands: [["/usr/bin/true"]], commandScope: ["/fixture/scope"])
            let model = DiskModel(report: .init(items: [item], denied: [], started: Date(), duration: 0))
            model.selected = [item.id]
            XCTAssertTrue(model.confirmationIsDestructive)
            XCTAssertFalse(model.planLines[0].contains("(0 "))
        }
    }
    @MainActor func testTrashOnlyConfirmationAndEmptySelectionAreNotPermanent() {
        for safety in [Safety.safe, .review, .risky] {
            let item = CleanItem(id: "fixture", category: .system, title: "fixture", safety: safety, bytes: 1, paths: ["/fixture/data"])
            let model = DiskModel(report: .init(items: [item], denied: [], started: Date(), duration: 0))
            XCTAssertFalse(model.confirmationIsDestructive)
            model.selected = [item.id]
            XCTAssertEqual(model.confirmationIsDestructive, safety == .safe)
        }
    }
    private final class Calls: @unchecked Sendable {
        let lock = NSLock(); private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
}
