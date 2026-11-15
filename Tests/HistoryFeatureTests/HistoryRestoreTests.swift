import XCTest
import AppKit
import ThermoL10n
import AgentCore
@testable import CleanKit
@testable import HistoryFeature

final class HistoryRestoreTests: XCTestCase {
    @MainActor func testRestoreFeedbackSeparatesAlreadyRestoredItemFromTheCurrentAttempt() async {
        let entry = record()
        let review = TrashRestore(id: entry.undo!.ref, dryRun: true, items: [
            .init(original: "/restored", destination: "/trash/a", bytes: 1, status: "restored"),
            .init(original: "/already", destination: "/trash/b", bytes: 1, status: "alreadyRestored", reason: "fixture already at original")
        ], reviewIdentity: "fixture")
        let model = HistoryModel(reader: { .init(records: []) }, restoreBatch: { id, _ in
            .init(id: id, dryRun: false, items: [
                .init(original: "/restored", destination: "/trash/a", bytes: 1, status: "restored"),
                .init(original: "/already", destination: "/trash/b", bytes: 1, status: "alreadyRestored", reason: "fixture already at original")
            ])
        }, didRestore: { _ in })
        model.restore(entry, review: review)
        for _ in 0..<200 where model.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.notice?.hasPrefix(tr("%1$@ of %2$@ items put back.", "1", "1")) == true)
        XCTAssertTrue(model.notice?.contains(tr("%1$@ items were already at their original locations.", "1")) == true)
        XCTAssertFalse(model.notice?.contains("/already:") == true)
    }

    @MainActor func testActuallyMissingItemRemainsVisibleAndIncomplete() async {
        let entry = record()
        let review = TrashRestore(id: entry.undo!.ref, dryRun: true, items: [
            .init(original: "/restored", destination: "/trash/a", bytes: 1, status: "restored"),
            .init(original: "/missing", destination: "/trash/b", bytes: 1, status: "restored")
        ], reviewIdentity: "fixture")
        let model = HistoryModel(reader: { .init(records: []) }, restoreBatch: { id, _ in
            .init(id: id, dryRun: false, items: [
                .init(original: "/restored", destination: "/trash/a", bytes: 1, status: "restored"),
                .init(original: "/missing", destination: "/trash/b", bytes: 1, status: "missing", reason: "fixture truly missing")
            ])
        }, didRestore: { _ in })
        model.restore(entry, review: review)
        for _ in 0..<200 where model.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.notice?.hasPrefix(tr("%1$@ of %2$@ items put back.", "1", "2")) == true)
        XCTAssertTrue(model.notice?.contains("/missing: fixture truly missing") == true)
    }

    @MainActor func testRestoreReportsCacheIssueWithoutLosingSuccessfulPaths() async throws {
        var paths: [String] = []
        let model = HistoryModel(reader: { .init(records: []) }, restoreBatch: { id, _ in
            .init(id: id, dryRun: false, items: [.init(original: "/restored", destination: "/trash", bytes: 1, status: "restored")], issues: ["cache warning fixture"])
        }, didRestore: { paths = $0 })
        let entry = record(); model.restore(entry, review: review(entry))
        for _ in 0..<100 where model.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(paths, ["/restored"]); XCTAssertTrue(model.notice?.contains("cache warning fixture") == true)
    }
    func review(_ record: OperationRecord) -> TrashRestore {
        .init(id: record.undo!.ref, dryRun: true, items: [.init(original: "/restored", destination: "/trash/a", bytes: 1, status: "restored")], reviewIdentity: "fixture")
    }
    func record() -> OperationRecord {
        .init(feature: "apps", action: "uninstall", items: [.init(target: "/fixture", status: "done")],
              undo: .init(kind: "trashBatch", ref: UUID().uuidString))
    }

    @MainActor func testRestoreCancelledBeforePhysicalWorkClearsBusy() async {
        let model = HistoryModel(reader: { .init(records: []) }, restoreBatch: { _, _ in
            XCTFail("cancelled restore must not touch files")
            throw NSError(domain: "fixture", code: 1)
        }, didRestore: { _ in XCTFail("nothing was restored") })
        let entry = record()
        model.restore(entry, review: review(entry))
        XCTAssertTrue(model.busy)
        // The detached worker cannot pass its MainActor admission check until this yields.
        model.work.cancel()
        await model.work.finish()
        XCTAssertFalse(model.busy)
    }

    @MainActor func testFailedRestoreDoesNotInvalidateSuccessfulData() async {
        let model = HistoryModel(reader: { .init(records: []) }, restoreBatch: { _, _ in throw NSError(domain: "fixture", code: 1) },
                                 didRestore: { _ in XCTFail("nothing was restored") })
        let entry = record(); model.restore(entry, review: review(entry))
        for _ in 0..<100 where model.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.busy); XCTAssertNotNil(model.notice)
    }

}
