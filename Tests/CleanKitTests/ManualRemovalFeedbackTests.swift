@testable import CleanKit
import ThermoL10n
import XCTest

final class ManualRemovalFeedbackTests: XCTestCase {
    func testAllFailuresDoNotClaimThatZeroItemsMovedSuccessfully() {
        var result = CleanResult(id: "manual", trashed: true)
        result.failed["/fixture/changed"] = "changed after review"
        let lines = ManualRemoval.feedback(result)
        XCTAssertEqual(lines.first, tr("Nothing was moved to the Trash."))
        XCTAssertTrue(lines.joined().contains("/fixture/changed"))
        XCTAssertTrue(lines.joined().contains("changed after review"))
    }
    func testPartialSuccessRetainsMovedCountUnknownSizeAndFailureReason() {
        var result = CleanResult(id: "manual", trashed: true)
        result.removed = ["/fixture/moved"]; result.bytesIncomplete = true
        result.failed["/fixture/kept"] = "busy"
        let lines = ManualRemoval.feedback(result)
        XCTAssertEqual(lines.first, tr("Moved %1$@ to the Trash (%2$@).", trCount(1, "%1$@ item", "%1$@ items"), tr("Size unavailable")))
        XCTAssertTrue(lines.dropFirst().joined().contains("/fixture/kept (busy)"))
        XCTAssertFalse(lines.dropFirst().joined().contains("/fixture/moved"))
    }
    func testWhitelistOnlyReportsPreservationInsteadOfSilentlyDoingNothing() {
        var result = CleanResult(id: "manual", trashed: true)
        result.whitelisted = ["/fixture/z", "/fixture/a", "/fixture/z"]
        XCTAssertEqual(ManualRemoval.feedback(result), [tr("Nothing was moved to the Trash."), tr("Kept by the whitelist: %1$@", "/fixture/a; /fixture/z")])
    }
    func testPostMoveRecordingAndCacheErrorsDoNotSayTheFileWasNotMoved() {
        var result = CleanResult(id: "manual", trashed: true)
        result.removed = ["/fixture/moved"]; result.bytes = 8
        result.failed["batch//fixture/moved"] = "recovery could not be recorded"
        result.failed["cache"] = "cache could not be cleared"
        let lines = ManualRemoval.feedback(result)
        XCTAssertFalse(lines.joined().contains(tr("Not moved: %1$@", "")))
        XCTAssertTrue(lines.contains(tr("Recovery record issue: %1$@", "recovery could not be recorded")))
        XCTAssertTrue(lines.contains("cache could not be cleared"))
        XCTAssertFalse(lines.joined().contains("batch//fixture/moved"))
    }
}
