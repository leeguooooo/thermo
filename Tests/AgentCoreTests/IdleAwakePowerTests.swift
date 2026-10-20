import XCTest
import IOKit.ps
@testable import AgentCore

@MainActor final class IdleAwakePowerTests: XCTestCase {
    private func row(_ current: NSNumber = 50, max: NSNumber = 100,
                     type: String = kIOPSInternalBatteryType, state: String = kIOPSBatteryPowerValue) -> [String: Any] {
        [kIOPSTypeKey: type, kIOPSPowerSourceStateKey: state,
         kIOPSCurrentCapacityKey: current, kIOPSMaxCapacityKey: max]
    }
    func testEmptyOrUnknownProviderCannotBecomeUnlimitedPowerButConfirmedACWorks() {
        for provider in [nil, kIOPMBatteryPowerKey, kIOPMUPSPowerKey, "unrecognized"] {
            let value = IdleAwakePower.decode(providing: provider, descriptions: [])
            XCTAssertEqual(value.source, .unknown); XCTAssertFalse(value.allowsStart)
        }
        let desktop = IdleAwakePower.decode(providing: kIOPMACPowerKey, descriptions: [])
        XCTAssertEqual(desktop.source, .external); XCTAssertTrue(desktop.allowsStart)
        XCTAssertTrue(IdleAwakePower.decode(providing: kIOPMACPowerKey, descriptions: [nil]).allowsStart)
        XCTAssertFalse(IdleAwakePower.decode(providing: nil, descriptions: [row()]).allowsStart)
    }
    func testValidCapacitiesAndLowBatteryBoundaryRemainSupported() {
        XCTAssertEqual(IdleAwakePower.decode(providing: kIOPMBatteryPowerKey,
                                            descriptions: [row(25, max: 50)]).percent, 50)
        for percent in [0, 20, 21, 100] {
            let value = IdleAwakePower.decode(providing: kIOPMBatteryPowerKey,
                                              descriptions: [row(NSNumber(value: percent))])
            XCTAssertEqual(value.percent, percent)
            XCTAssertEqual(value.allowsStart, percent > 20)
        }
    }
    func testInvalidCapacityIsUnknownRatherThanClampedToHealthyBattery() {
        let invalid: [(NSNumber, NSNumber)] = [
            (101, 100), (-1, 100), (50, 0), (50, -1),
            (NSNumber(value: true), 100), (50, NSNumber(value: true)),
            (NSNumber(value: Double.nan), 100), (50, NSNumber(value: Double.infinity)),
            (NSNumber(value: Double.greatestFiniteMagnitude), 1),
        ]
        for (current, maximum) in invalid {
            let value = IdleAwakePower.decode(providing: kIOPMBatteryPowerKey,
                                              descriptions: [row(current, max: maximum)])
            XCTAssertEqual(value.source, .unknown); XCTAssertFalse(value.allowsStart)
        }
    }
    func testIncompleteContributingRecordCannotBeSkippedForAHealthyOne() {
        var missing = row(); missing.removeValue(forKey: kIOPSCurrentCapacityKey)
        for descriptions in [[nil, row(90)], [missing, row(90)]] {
            XCTAssertEqual(IdleAwakePower.decode(providing: kIOPMBatteryPowerKey,
                                                 descriptions: descriptions).source, .unknown)
        }
        XCTAssertEqual(IdleAwakePower.decode(providing: kIOPMBatteryPowerKey,
                                             descriptions: [row(90), row(10)]).percent, 10)
        var invalidType = row(); invalidType[kIOPSTypeKey] = "invalid"
        XCTAssertEqual(IdleAwakePower.decode(providing: kIOPMBatteryPowerKey,
                                             descriptions: [invalidType]).source, .unknown)
    }
    func testUPSUsesItsOwnStateAndCapacityInsteadOfInternalBattery() {
        let upsAC = row(type: kIOPSUPSType, state: kIOPSACPowerValue)
        XCTAssertEqual(IdleAwakePower.decode(providing: kIOPMUPSPowerKey,
                                             descriptions: [upsAC]).source, .external)
        XCTAssertEqual(IdleAwakePower.decode(providing: kIOPMUPSPowerKey,
                                             descriptions: [row(10), row(80, type: kIOPSUPSType)]).percent, 80)
        XCTAssertEqual(IdleAwakePower.decode(providing: kIOPMBatteryPowerKey,
                                             descriptions: [row(10), row(80, type: kIOPSUPSType)]).percent, 10)
        XCTAssertTrue(IdleAwakePower.decode(providing: kIOPMUPSPowerKey,
                                            descriptions: [row(10, type: kIOPSUPSType)]).low)
    }
    func testInvalidSnapshotPausesActiveRequestsAndRecoveryKeepsOriginalDeadline() throws {
        let backend = IdleAwakeTests.Fake(), now = Date(timeIntervalSince1970: 1000)
        let controller = IdleAwakeController(driver: backend.driver)
        try controller.start(mode: .both, seconds: 120, power: .init(source: .external), now: now)
        let invalid = IdleAwakePower.decode(providing: kIOPMBatteryPowerKey, descriptions: [row(110)])
        controller.tick(power: invalid, now: now.addingTimeInterval(10))
        XCTAssertEqual(controller.state.phase, .pausedPowerUnknown)
        XCTAssertTrue(backend.entries.isEmpty)
        controller.tick(power: IdleAwakePower.decode(providing: kIOPMBatteryPowerKey, descriptions: [row(50)]),
                        now: now.addingTimeInterval(20))
        XCTAssertEqual(controller.state.phase, .active)
        XCTAssertEqual(controller.state.expiresAt, now.addingTimeInterval(120))
        controller.tick(power: .init(source: .external), now: now.addingTimeInterval(121))
        XCTAssertEqual(controller.state.lastEndReason, "expired"); XCTAssertTrue(backend.entries.isEmpty)
    }
}
