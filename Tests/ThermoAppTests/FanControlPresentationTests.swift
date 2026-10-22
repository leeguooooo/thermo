import XCTest
import ThermoKit
import ThermoL10n
@testable import ThermoApp

final class FanControlPresentationTests: XCTestCase {
    func testMissingModeErrorHasReadableSummaryWithoutHidingOtherFailures() {
        let raw = "automatic control unconfirmed: fan 0: no automatic-control readback key"
        XCTAssertEqual(FanControlPresentation.errorText(raw), tr("Fan control could not be verified on this Mac. Open fan settings for details."))
        XCTAssertEqual(FanControlPresentation.errorText("write failed"), "write failed")
    }
    func testUnknownControlDoesNotSelectAutomaticAndExplicitRequestsRemainVisible() {
        func selected(_ state: FanControlState?, available: Bool = true, policies: [Int: FanPolicy] = [:], pending: [Int: FanPolicy] = [:]) -> FanPolicy? {
            FanControlPresentation.selectedPolicy(fan: 0, available: available, policies: policies, pending: pending, state: state)
        }
        XCTAssertNil(selected(nil))
        XCTAssertNil(selected(.init(policies: [:])))
        var automatic = FanControlState(policies: [:], observations: [0: .init(mode: .automatic)])
        XCTAssertEqual(selected(automatic), .auto)
        XCTAssertNil(selected(automatic, available: false))
        automatic.failure = "no readback"
        XCTAssertNil(selected(automatic))
        XCTAssertEqual(selected(automatic, policies: [0: .fixed(rpm: 6000)]), .fixed(rpm: 6000))
        XCTAssertEqual(selected(nil, available: false, pending: [0: .auto]), .auto)
        XCTAssertNil(selected(.init(policies: [:], observations: [0: .init(mode: .manual, target: 6000)])))
    }

    func testSpeedSummaryDistinguishesFanlessUnknownAndPartiallyMeasuredMaximum() {
        let unknown = FanReading(id: 0, name: "Missing", rpm: nil, min: nil, max: nil, target: nil, manual: nil)
        let known = FanReading(id: 1, name: "Known", rpm: 2000, min: 1200, max: 6000, target: nil, manual: false)
        XCTAssertNil(FanControlPresentation.speedSummary([]))
        XCTAssertEqual(FanControlPresentation.speedSummary([unknown]), tr("%1$@ rpm", tr("unknown")))
        XCTAssertEqual(FanControlPresentation.speedSummary([known]), tr("%1$@ rpm", "2000"))
        XCTAssertEqual(FanControlPresentation.speedSummary([unknown, known]), "≥ " + tr("%1$@ rpm", "2000"))
    }
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
        state.suspensionReason = .temperatureUnavailable
        XCTAssertEqual(FanControlPresentation.observation(state, fan: 0), tr("Temperature readings were lost; waiting for stable safe readings"))
        state.failure = "policy was not saved"
        XCTAssertEqual(FanControlPresentation.observation(state, fan: 0), tr("Control error: %1$@", "policy was not saved"))
    }
}
