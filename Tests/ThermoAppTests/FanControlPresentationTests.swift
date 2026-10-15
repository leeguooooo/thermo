import XCTest
import ThermoKit
import ThermoL10n
@testable import ThermoApp

final class FanControlPresentationTests: XCTestCase {
    func testPendingAndLegacyHelpersNeverRenderManualConfirmation() {
        let pending = FanControlState(policies: [0: .fixed(rpm: 3000)])
        XCTAssertEqual(FanControlPresentation.observation(pending, fan: 0), tr("Waiting for hardware verification"))
        let legacy = FanControlState(policies: pending.policies, observationsSupported: false)
        XCTAssertEqual(FanControlPresentation.observation(legacy, fan: 0), tr("Hardware verification unavailable"))
        XCTAssertEqual(FanControlPresentation.observation(nil, fan: 0), tr("Hardware verification unavailable"))
    }

    func testAutomaticFallbackAndFaultAreShownAlongsideDifferentDesiredPolicy() {
        var state = FanControlState(policies: [0: .curve(.quiet)], observations: [0: .init(mode: .automatic)])
        XCTAssertEqual(FanControlPresentation.observation(state, fan: 0), tr("Last register check: automatic control"))
        state.suspended = true
        XCTAssertEqual(FanControlPresentation.observation(state, fan: 0), tr("Manual policies suspended for thermal safety"))
        state.failure = "policy was not saved"
        XCTAssertEqual(FanControlPresentation.observation(state, fan: 0), tr("Control error: %1$@", "policy was not saved"))
    }
}
