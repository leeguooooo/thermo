import XCTest
@testable import CaptureCore

final class CaptureAutoScrollTests: XCTestCase {
    func testStepKeepsAnOverlapAndHasAFloor() {
        XCTAssertEqual(CaptureAutoScroll.step(viewport: 500), 300)
        XCTAssertEqual(CaptureAutoScroll.step(viewport: 30), 40)
        XCTAssertEqual(CaptureAutoScroll.step(viewport: .nan), 40)
    }

    func testStopsAfterThreeFramesWithNothingNewAtTheEndOfThePage() {
        var pacing = CaptureAutoScroll()
        XCTAssertEqual(pacing.record(duplicate: false, failed: false), .scroll)
        XCTAssertEqual(pacing.record(duplicate: true, failed: false), .scroll)   // one slow repaint is not the end
        XCTAssertEqual(pacing.record(duplicate: false, failed: false), .scroll)
        XCTAssertEqual(pacing.record(duplicate: true, failed: false), .scroll)
        XCTAssertEqual(pacing.record(duplicate: true, failed: false), .scroll)
        XCTAssertEqual(pacing.record(duplicate: true, failed: false), .finished)
    }

    func testGivesUpAfterThreeFailedStitchesInARow() {
        var pacing = CaptureAutoScroll()
        XCTAssertEqual(pacing.record(duplicate: false, failed: true), .scroll)
        XCTAssertEqual(pacing.record(duplicate: false, failed: false), .scroll)  // a success resets the count
        XCTAssertEqual(pacing.record(duplicate: false, failed: true), .scroll)
        XCTAssertEqual(pacing.record(duplicate: false, failed: true), .scroll)
        XCTAssertEqual(pacing.record(duplicate: false, failed: true), .gaveUp)
    }

    func testFrameCapEndsRunawayPages() {
        var pacing = CaptureAutoScroll()
        var last = CaptureAutoScroll.Next.scroll
        for _ in 0..<CaptureAutoScroll.maximumFrames { last = pacing.record(duplicate: false, failed: false) }
        XCTAssertEqual(last, .finished)
    }
}
