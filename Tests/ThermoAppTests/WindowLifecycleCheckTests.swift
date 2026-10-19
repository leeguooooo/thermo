@testable import ThermoApp
import XCTest

final class WindowLifecycleCheckTests: XCTestCase {
    func testVerificationRequiresOffscreenAbsolutePathAndBoundedFiniteDurations() throws {
        let base = ["ThermoApp", "--offscreen", "--verify-lifecycle", "/tmp/report.json"]
        let options = try WindowLifecycleCheck.Options(arguments: base)
        XCTAssertEqual(options.cycles, 3)
        XCTAssertFalse(options.foregroundActivity)
        XCTAssertTrue(try WindowLifecycleCheck.Options(arguments: base + ["--foreground-activity"]).foregroundActivity)
        for arguments in [
            ["ThermoApp", "--verify-lifecycle", "/tmp/report.json"],
            ["ThermoApp", "--offscreen", "--verify-lifecycle", "relative.json"],
            base + ["--cycles", "1000"], base + ["--open-seconds", "nan"],
            base + ["--idle-seconds", "inf"], base + ["--cycles"]
        ] { XCTAssertThrowsError(try WindowLifecycleCheck.Options(arguments: arguments)) }
    }
}
