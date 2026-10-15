import XCTest
@testable import ThermoKit

final class FanControlStateTests: XCTestCase {
    func testAcceptedPolicyHasNoHardwareConfirmationAndLegacyClientsRejectIt() throws {
        var state = FanControlState(policies: [0: .fixed(rpm: 3000)])
        XCTAssertEqual(state.verification(for: 0), .pending)
        XCTAssertNotNil(state.legacyError)
        let reply = try FanPolicyReply.encode(state.policies, recovery: nil, controlError: state.legacyError)
        XCTAssertThrowsError(try FanPolicyReply.decode(reply))
        state.observations[0] = .init(mode: .manual, target: 3000)
        XCTAssertEqual(state.verification(for: 0), .checked)
        XCTAssertNil(state.legacyError)
    }

    func testSuspensionAndSensorFallbackDoNotBecomeActiveManualPolicies() {
        var state = FanControlState(policies: [0: .curve(.quiet), 1: .fixed(rpm: 6000)],
            observations: [0: .init(mode: .automatic), 1: .init(mode: .manual, target: 6000)], suspended: true)
        XCTAssertEqual(state.verification(for: 0), .suspended)
        XCTAssertEqual(state.verification(for: 1), .checked, "full cooling can remain manual during thermal protection")
        XCTAssertNotNil(state.legacyError)
        state.suspended = false
        XCTAssertNotNil(state.legacyError, "automatic sensor fallback is not an active curve")
        state.failure = "automatic recovery unconfirmed"
        XCTAssertEqual(state.verification(for: 1), .failed)
    }

    func testLegacyHelperAndInvalidObservationStayUnavailable() {
        let legacy = FanControlState(policies: [0: .fixed(rpm: 3000)], observationsSupported: false)
        XCTAssertEqual(legacy.verification(for: 0), .unavailable)
        for target in [Double.nan, Double.infinity, -1] {
            let invalid = FanControlState(policies: [:], observations: [0: .init(mode: .manual, target: target)])
            XCTAssertEqual(invalid.verification(for: 0), .unavailable)
            var desired = invalid; desired.policies[0] = .fixed(rpm: 3000)
            XCTAssertNotNil(desired.legacyError)
        }
    }

    func testStateRoundTripKeepsDesiredTargetObservedModeAndCheckTimeSeparate() throws {
        let state = FanControlState(policies: [0: .fixed(rpm: 2500)],
            observations: [0: .init(mode: .automatic, checkedAt: Date(timeIntervalSince1970: 1000))], failure: "target refused")
        let decoded = try PolicyCoding.decoder().decode(FanControlState.self, from: PolicyCoding.encoder().encode(state))
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.policies[0], .fixed(rpm: 2500))
        XCTAssertEqual(decoded.observations[0]?.mode, .automatic)
        XCTAssertNil(decoded.observations[0]?.target)
    }
}
