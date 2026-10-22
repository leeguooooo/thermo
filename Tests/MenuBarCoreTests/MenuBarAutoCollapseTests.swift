import XCTest
@testable import MenuBarCore

@MainActor final class MenuBarAutoCollapseTests: XCTestCase {
    func testCancelAndReplacementCannotFireAnOlderAction() async throws {
        let timer = MenuBarAutoCollapse()
        var actions: [String] = []
        timer.schedule(after: 0) { actions.append("cancelled") }
        timer.cancel()
        timer.schedule(after: 0) { actions.append("replaced") }
        timer.schedule(after: 1_000_000) { actions.append("current") }
        for _ in 0..<100 {
            if actions == ["current"] { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(actions, ["current"])
        XCTAssertFalse(timer.isScheduled)
        try await Task.sleep(nanoseconds: 3_000_000)
        XCTAssertEqual(actions, ["current"], "Auto-collapse fires once, not repeatedly")
    }

    func testCancelAnArmedDeadlineImmediatelyReleasesIt() async throws {
        let timer = MenuBarAutoCollapse()
        var fired = false
        timer.schedule(after: 1_000_000) { fired = true }
        XCTAssertTrue(timer.isScheduled)
        timer.cancel()
        XCTAssertFalse(timer.isScheduled)
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertFalse(fired)
    }

    func testOnlySupportedPreferenceValuesHaveDeadlines() {
        XCTAssertNil(MenuBarAutoCollapseDelay.disabled.nanoseconds)
        XCTAssertEqual(MenuBarAutoCollapseDelay.tenSeconds.nanoseconds, 10_000_000_000)
        XCTAssertEqual(MenuBarAutoCollapseDelay.thirtySeconds.nanoseconds, 30_000_000_000)
        XCTAssertEqual(MenuBarAutoCollapseDelay.oneMinute.nanoseconds, 60_000_000_000)
        XCTAssertNil(MenuBarAutoCollapseDelay(rawValue: -1))
        XCTAssertNil(MenuBarAutoCollapseDelay(rawValue: 1))
        XCTAssertNil(MenuBarAutoCollapseDelay(rawValue: 3600))
    }
}
