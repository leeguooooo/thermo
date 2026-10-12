import XCTest
@testable import CleanKit

final class PulseActionReviewTests: XCTestCase {
    let time = Date(timeIntervalSince1970: 1_791_680_000)
    func pulse(at seconds: Double, memory: MachinePulse.Memory = .warning) -> MachinePulse {
        MachinePulse(load1: 10, load5: 10, cores: 8, thermal: .nominal, memory: memory,
                     swapUsedMB: 12_000, hogs: [], sampled: time.addingTimeInterval(seconds))
    }
    func hog(memory: Int = 4 * 1_048_576) -> MachinePulse.Hog {
        .init(id: "/Fixture.app", name: "Fixture", cpu: 0, memoryKB: memory, pids: [42], app: "/Fixture.app", quittable: true)
    }
    func testMemoryPressurePrioritizesInspectingHeavyBrowserPages() {
        var browser = hog(); browser.name = "Google Chrome"
        var protected = hog(memory: 32 * 1_048_576); protected.id = "agent"; protected.name = "codex"; protected.quittable = false
        var reading = pulse(at: 0); reading.hogs = [protected, browser]
        XCTAssertEqual(reading.nextStep?.kind, "inspectBrowser")
        XCTAssertEqual(reading.nextStep?.program, "Google Chrome")
        reading.memory = .normal; reading.load1 = 1
        XCTAssertNil(reading.nextStep, "a normal reading must not push an unnecessary quit or restart")
    }
    func testSmallProgramsAreNotPresentedAsTheMemoryFix() {
        var reading = pulse(at: 0); reading.hogs = [hog(memory: 1024)]
        XCTAssertEqual(reading.nextStep?.kind, "pauseWork")
        XCTAssertNil(reading.nextStep?.program)
    }
    func testThermalPressurePrioritizesReducingWork() {
        var reading = pulse(at: 0); reading.thermal = .serious; reading.hogs = [hog()]
        XCTAssertEqual(reading.nextStep?.kind, "pauseWork")
    }
    func testMemoryDropDoesNotClaimThatSystemPressureRecovered() {
        let result = PulseActionReview(action: .restart, target: hog(), before: pulse(at: 0), after: pulse(at: 5),
                                       afterTarget: hog(memory: 1_048_576))
        XCTAssertEqual(result.outcome, .memoryDecreased)
        XCTAssertEqual(result.memoryAfter, .warning)
        XCTAssertEqual(result.thermalAfter, .nominal)
        XCTAssertEqual(result.afterMemoryKB, 1_048_576)
    }
    func testMissingReopenedAppIsFailureRatherThanZeroMemorySuccess() {
        let result = PulseActionReview(action: .restart, target: hog(), before: pulse(at: 0), after: pulse(at: 5), afterTarget: nil)
        XCTAssertEqual(result.outcome, .notReopened)
        XCTAssertNil(result.afterMemoryKB)
    }
    func testRefusedQuitAndGrowingMemoryDoNotReportImprovement() {
        let stillRunning = PulseActionReview(action: .quit, target: hog(), before: pulse(at: 0), after: pulse(at: 5), afterTarget: hog())
        XCTAssertEqual(stillRunning.outcome, .stillRunning)
        let increased = PulseActionReview(action: .restart, target: hog(), before: pulse(at: 0), after: pulse(at: 5), afterTarget: hog(memory: 6 * 1_048_576))
        XCTAssertEqual(increased.outcome, .noClearDecrease)
        let jitter = PulseActionReview(action: .restart, target: hog(), before: pulse(at: 0), after: pulse(at: 5), afterTarget: hog(memory: 4 * 1_048_576 - 1024))
        XCTAssertEqual(jitter.outcome, .noClearDecrease)
    }
    func testMissingInventoryCannotBeReportedAsSuccessfulQuit() {
        let result = PulseActionReview(action: .quit, target: hog(), before: pulse(at: 0), after: pulse(at: 5),
                                       afterTarget: nil, inventoryAvailable: false)
        XCTAssertEqual(result.outcome, .unavailable)
    }
    func testIdleReopenedAppIsFoundInFullInventory() {
        let idle = hog(memory: 64 * 1024)
        let found = PulseActionReview.findTarget(hog(), in: [idle])
        XCTAssertNotNil(found, "zero CPU must not mean that the application failed to reopen")
        XCTAssertNil(PulseActionReview.findTarget(hog(), in: []))
    }
    func testStaleAndInvalidFollowUpReadingsAreUnavailable() {
        for seconds in [-5.0, 0, 181] {
            let result = PulseActionReview(action: .restart, target: hog(), before: pulse(at: 0), after: pulse(at: seconds), afterTarget: hog(memory: 1024))
            XCTAssertEqual(result.outcome, .unavailable)
        }
        let invalid = PulseActionReview(action: .restart, target: hog(), before: pulse(at: 0), after: pulse(at: 5), afterTarget: hog(memory: -1))
        XCTAssertEqual(invalid.outcome, .unavailable)
    }
}
