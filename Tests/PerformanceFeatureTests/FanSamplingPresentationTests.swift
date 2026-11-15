import XCTest
import ThermoKit
import ThermoL10n
@testable import PerformanceFeature

@MainActor final class FanSamplingPresentationTests:XCTestCase {
    func testMissingReadingsKeepSavedPendingAndObservationOnlyControlsSeparateFromLiveFans() {
        let state = FanControlState(policies: [0: .fixed(rpm: 3000)], observations: [1: .init(mode: .automatic)])
        let policies = state.policies, pending: [Int: FanPolicy] = [2: .curve(.quiet)]
        XCTAssertEqual(FanControlPresentation.missingFanIDs(readings: nil, policies: policies, pending: pending, state: state), [0, 1, 2])
        let recovered = FanReading(id: 0, name: "Fixture", rpm: 2500, min: nil, max: nil, target: nil, manual: nil)
        XCTAssertEqual(FanControlPresentation.missingFanIDs(readings: [recovered], policies: policies, pending: pending, state: state), [1, 2])
        XCTAssertEqual(FanControlPresentation.missingFanIDs(readings: [], policies: [:], pending: [:], state: nil), [])
    }
    func testKnownControlFailureSurvivesUnsupportedHardwareVerification() {
        let state = FanControlState(policies: [0: .auto], failure: "fixture control failure", observationsSupported: false)
        XCTAssertTrue(FanControlPresentation.observation(state, fan: 0).contains("fixture control failure"))
    }
}
