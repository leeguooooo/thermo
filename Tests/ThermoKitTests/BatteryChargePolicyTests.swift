import XCTest
@testable import ThermoKit

final class BatteryChargePolicyTests: XCTestCase {
    typealias Policy = BatteryChargePolicy
    func observation(_ percent: Double?, plugged: Bool? = true, time: Double = 100) -> Policy.Observation {
        .init(percent: percent, externalPower: plugged, observedAt: time)
    }

    func testLimitStartsAt80OnlyWhenPluggedAndUnowned() {
        for percent in [0.0, 74, 75, 79.99] {
            XCTAssertEqual(Policy.limit80.decision(observation: observation(percent), now: 100, gate: .allowed, ownership: .none), .leaveUnchanged)
        }
        for percent in [80.0, 81, 100] {
            XCTAssertEqual(Policy.limit80.decision(observation: observation(percent), now: 100, gate: .allowed, ownership: .none), .inhibit)
            XCTAssertEqual(Policy.limit80.decision(observation: observation(percent, plugged: false), now: 100, gate: .allowed, ownership: .none), .leaveUnchanged)
        }
    }

    func testOwnedHoldUsesHysteresisAndReleasesBelow75() {
        for percent in [75.0, 75.01, 79, 80, 100] {
            XCTAssertEqual(Policy.limit80.decision(observation: observation(percent), now: 100, gate: .inhibited, ownership: .owned), .leaveUnchanged)
        }
        for percent in [0.0, 74, 74.99] {
            XCTAssertEqual(Policy.limit80.decision(observation: observation(percent), now: 100, gate: .inhibited, ownership: .owned), .restoreOwned)
        }
        XCTAssertEqual(Policy.limit80.decision(observation: observation(90, plugged: false), now: 100, gate: .inhibited, ownership: .owned), .restoreOwned)
    }

    func testUnknownAndStalePowerCannotAcquireHoldAndReleaseOurHold() {
        let invalid: [Policy.Observation?] = [nil, observation(nil), observation(-1), observation(101), observation(.nan), observation(.infinity), observation(90, plugged: nil), observation(90, time: 69.99), observation(90, time: 100.01), observation(90, time: .nan), observation(90, time: -1)]
        for sample in invalid {
            XCTAssertEqual(Policy.limit80.decision(observation: sample, now: 100, gate: .allowed, ownership: .none), .observationUnavailable)
            XCTAssertEqual(Policy.limit80.decision(observation: sample, now: 100, gate: .inhibited, ownership: .owned), .restoreOwned)
        }
        XCTAssertEqual(Policy.limit80.decision(observation: observation(90, time: 70), now: 100, gate: .allowed, ownership: .none), .inhibit)
        for now in [Double.nan, .infinity, -.infinity, -1] {
            XCTAssertEqual(Policy.limit80.decision(observation: observation(90), now: now, gate: .allowed, ownership: .none), .observationUnavailable)
        }
    }

    func testOffAndTemporaryFullReleaseOnlyOurLeaseWithoutNeedingPowerReading() {
        for policy in [Policy.off, .chargeToFull] {
            XCTAssertEqual(policy.decision(observation: nil, now: .nan, gate: .inhibited, ownership: .owned), .restoreOwned)
            XCTAssertEqual(policy.decision(observation: nil, now: .nan, gate: .allowed, ownership: .none), .leaveUnchanged)
        }
    }

    func testExternalHoldIsNeverClaimedOrReleasedByAnyPolicy() {
        for policy in [Policy.off, .limit80, .chargeToFull] {
            for sample in [nil, observation(0), observation(100)] {
                XCTAssertEqual(policy.decision(observation: sample, now: 100, gate: .inhibited, ownership: .none), .externalHold)
            }
        }
    }

    func testPartialTransactionsAndLostGateReadbackRequireRecovery() {
        for policy in [Policy.off, .limit80, .chargeToFull] {
            for gate in [Policy.Gate.allowed, .inhibited, .unknown] {
                XCTAssertEqual(policy.decision(observation: observation(90), now: 100, gate: gate, ownership: .uncertain), .recoveryRequired)
            }
            XCTAssertEqual(policy.decision(observation: observation(90), now: 100, gate: .unknown, ownership: .owned), .recoveryRequired)
            XCTAssertEqual(policy.decision(observation: observation(90), now: 100, gate: .unknown, ownership: .none), .observationUnavailable)
        }
        XCTAssertEqual(Policy.limit80.decision(observation: observation(90), now: 100, gate: .allowed, ownership: .owned), .recoveryRequired)
    }
}
