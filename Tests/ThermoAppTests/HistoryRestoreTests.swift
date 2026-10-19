import XCTest
import AppKit
import ThermoL10n
import AgentCore
@testable import CleanKit
@testable import ThermoApp

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

    @MainActor func testConfirmedRestoreBlocksQuitAndReportsOnlyActuallyRestoredPaths() async {
        let began = expectation(description: "restore starts"); began.assertForOverFulfill = true
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var paths: [String] = []
        let model = HistoryModel(reader: { .init(records: []) }, restoreBatch: { id, _ in
            began.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return TrashRestore(id: id, dryRun: false, items: [
                .init(original: "/restored", destination: "/trash/a", bytes: 1, status: "restored"),
                .init(original: "/kept", destination: "/trash/b", bytes: 1, status: "conflict")])
        }, didRestore: { paths = $0 })
        let entry = record(); model.restore(entry, review: review(entry))
        await fulfillment(of: [began], timeout: 2)
        XCTAssertTrue(model.busy)
        var shown: [MainPage] = []
        XCTAssertEqual(AppExitGuard.reply(show: { shown.append($0) }), .terminateCancel)
        XCTAssertEqual(shown, [.history])
        model.restore(entry, review: review(entry))
        release.signal()
        for _ in 0..<100 where model.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.busy)
        XCTAssertEqual(paths, ["/restored"])
        XCTAssertEqual(AppExitGuard.reply(show: { _ in XCTFail("completed restore must allow exit") }), .terminateNow)
    }

    @MainActor func testFailedRestoreReleasesExitGuardWithoutInvalidatingSuccessfulData() async {
        let model = HistoryModel(reader: { .init(records: []) }, restoreBatch: { _, _ in throw NSError(domain: "fixture", code: 1) },
                                 didRestore: { _ in XCTFail("nothing was restored") })
        let entry = record(); model.restore(entry, review: review(entry))
        for _ in 0..<100 where model.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.busy); XCTAssertNotNil(model.notice)
        XCTAssertEqual(AppExitGuard.reply(show: { _ in XCTFail("failed restore must release exit guard") }), .terminateNow)
    }

    @MainActor func testRestoreInvalidationClearsOldOutcomeAndCancelsAStaleReview() async {
        let began = expectation(description: "review starts")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = AppsModel(reviewPlan: { app, _, _, _ in
            began.fulfill(); _ = release.wait(timeout: .now() + 5)
            return UninstallPlan(app: app, paths: [], bytes: 0)
        })
        model.outcome = "old removal result"
        model.review(InstalledApp(path: "/fixture.app", name: "Fixture", bundleID: "com.example.fixture"))
        await fulfillment(of: [began], timeout: 2)
        model.invalidateAfterRestore()
        XCTAssertNil(model.outcome); XCTAssertNil(model.plan)
        release.signal()
        for _ in 0..<100 where model.planning != nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(model.planning); XCTAssertNil(model.plan)
    }
}
