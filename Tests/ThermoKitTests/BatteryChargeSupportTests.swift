import XCTest
@testable import ThermoKit

final class BatteryChargeSupportTests: XCTestCase {
    func testPowerSourcePresenceRequiresACompleteKnownAbsence() {
        XCTAssertEqual(BatteryChargeSystem.presence(sourceTypes: []), .notObserved)
        XCTAssertEqual(BatteryChargeSystem.presence(sourceTypes: ["UPS"]), .notObserved)
        for types: [String?] in [[nil], ["unexpected"], ["UPS", nil]] {
            XCTAssertEqual(BatteryChargeSystem.presence(sourceTypes: types), .unknown)
        }
        XCTAssertEqual(BatteryChargeSystem.presence(sourceTypes: [nil, "InternalBattery"]), .present)
        XCTAssertEqual(BatteryChargeSystem.presence(sourceTypes: [], registryBatteryPresent: true), .unknown)
        XCTAssertEqual(BatteryChargeSystem.presence(sourceTypes: ["UPS"], registryBatteryPresent: true), .unknown)
    }
    func testNativeEligibilityAndFallbackDoNotClaimAnActiveSystemSetting() {
        XCTAssertFalse(BatteryChargeSystem.nativeLimitEligible(major: 26, minor: 3, appleSilicon: true))
        XCTAssertFalse(BatteryChargeSystem.nativeLimitEligible(major: 27, minor: 0, appleSilicon: false))
        XCTAssertTrue(BatteryChargeSystem.nativeLimitEligible(major: 26, minor: 4, appleSilicon: true))
        XCTAssertTrue(BatteryChargeSystem.nativeLimitEligible(major: 27, minor: 0, appleSilicon: true))
        XCTAssertEqual(BatteryChargeProbe.support(presence: .present, availability: .unsupported, nativeEligible: true), .systemSettings)
        XCTAssertEqual(BatteryChargeProbe.support(presence: .present, availability: .unavailable, nativeEligible: true), .unknown)
        XCTAssertEqual(BatteryChargeProbe.support(presence: .unknown, availability: .available, nativeEligible: true), .unknown)
        XCTAssertEqual(BatteryChargeProbe.support(presence: .notObserved, availability: .available, nativeEligible: true), .noInternalBattery)
        XCTAssertEqual(BatteryChargeProbe.support(presence: .present, availability: .available, nativeEligible: true), .smc)
    }
    func testProbeReadsMetadataAndBytesWithoutAStoreOrWriter() {
        let f = BatteryChargingGateTests.Fixture(.chte)
        let result = BatteryChargeProbe.capture(io: f.io, presence: .present, nativeEligible: true)
        XCTAssertEqual(result.support, .smc); XCTAssertEqual(result.gate, .allowed)
        XCTAssertEqual(result.registers.count, 3); XCTAssertFalse(result.changesMade); XCTAssertFalse(result.sessionStateQueried)
        XCTAssertTrue(f.writes.isEmpty); XCTAssertNil(f.saved)
        f.values["CHTE"] = [1, 0, 0, 0]
        XCTAssertEqual(BatteryChargeProbe.capture(io: f.io, presence: .present, nativeEligible: true).gate, .inhibited)
        XCTAssertTrue(f.writes.isEmpty)
    }
    func testUnknownBytesDoNotBecomeAllowedOrUnsupported() {
        let f = BatteryChargingGateTests.Fixture(.chte); f.values["CHTE"] = [7, 0, 0, 0]
        let result = BatteryChargeProbe.capture(io: f.io, presence: .present, nativeEligible: true)
        XCTAssertEqual(result.availability, .available); XCTAssertEqual(result.gate, .unknown); XCTAssertNotNil(result.error)
        XCTAssertTrue(f.writes.isEmpty)
        f.failRead = true
        let failed = BatteryChargeProbe.capture(io: f.io, presence: .present, nativeEligible: true)
        XCTAssertEqual(failed.gate, .unknown); XCTAssertNotNil(failed.registers.last?.error)
    }
    func testMissingKeysCanUseSystemSettingsButQueryErrorsRemainUnknown() {
        let f = BatteryChargingGateTests.Fixture(); f.metadata = [:]
        XCTAssertEqual(f.controller().availability(), .unsupported)
        XCTAssertEqual(BatteryChargeProbe.capture(io: f.io, presence: .present, nativeEligible: true).support, .systemSettings)
        var io = f.io; io.info = { _ in throw BatteryGateError("unavailable") }
        XCTAssertEqual(BatteryChargeProbe.capture(io: io, presence: .present, nativeEligible: true).support, .unknown)
        XCTAssertTrue(f.writes.isEmpty)
    }
}
