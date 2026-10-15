@testable import ThermoKit
import XCTest

final class FanRecoveryTests: XCTestCase {
    final class FakeSMC: FanSMCAccess {
        enum Fault: Error { case injected }
        var values: [FourCC: Double] = ["F0Md": 1, "F1Md": 1, "Ftst": 1, "FS! ": 3]
        var failedWrites = Set<FourCC>()
        var failedReads = Set<FourCC>()
        var ignoredWrites = Set<FourCC>()
        var writes: [(FourCC, Double)] = []
        var firmwareOnUnlockReset = false
        func double(_ key: FourCC) throws -> Double {
            guard !failedReads.contains(key), let value = values[key] else { throw Fault.injected }
            return value
        }
        func write(_ key: FourCC, value: Double) throws {
            writes.append((key, value))
            if failedWrites.contains(key) { throw Fault.injected }
            if !ignoredWrites.contains(key) { values[key] = value }
            if key == "Ftst", value == 0, firmwareOnUnlockReset {
                values["F0Md"] = 3; values["F1Md"] = 3
            }
        }
    }
    func discovery(apple: Bool = false, modes: Bool = true, force: Bool = false) -> Discovery {
        Discovery(version: Discovery.version, model: "Fixture", keyCount: 0, sensors: [],
                  fans: [FanDescriptor(index: 0, name: "Left", hasModeKey: modes), FanDescriptor(index: 1, name: "Right", hasModeKey: modes)],
                  fanForceKey: force, fanTestKey: apple, hid: false)
    }

    func testFailedFirstFanStillAttemptsEveryFanAndDoesNotConfirmAuto() {
        let smc = FakeSMC(); smc.failedWrites = ["F0Md"]
        let writer = FanWriter(smc: smc, discovery: discovery())
        let report = writer.setAllAuto()
        XCTAssertFalse(report.confirmed)
        XCTAssertTrue(smc.writes.contains { $0.0 == "F1Md" && $0.1 == 0 })
        XCTAssertEqual(smc.values["F1Md"], 0)
        smc.failedWrites = []
        XCTAssertTrue(writer.setAllAuto().confirmed, "a later successful retry can clear uncertainty")
    }

    func testSuccessfulWriteWithoutModeChangeIsUnconfirmed() {
        let smc = FakeSMC(); smc.ignoredWrites = ["F0Md", "F1Md"]
        let writer = FanWriter(smc: smc, discovery: discovery())
        XCTAssertThrowsError(try writer.setAuto(0))
        XCTAssertFalse(writer.setAllAuto().confirmed)
    }

    func testReadFailureDoesNotBecomeConfirmedAuto() {
        let smc = FakeSMC()
        let writer = FanWriter(smc: smc, discovery: discovery())
        smc.failedReads = ["F0Md"]
        XCTAssertFalse(writer.setAllAuto().confirmed)
    }

    func testAppleFirmwareFallbackCanConfirmAutoDespiteIndividualRequestFailure() {
        let smc = FakeSMC(); smc.failedWrites = ["F0Md", "F1Md"]; smc.firmwareOnUnlockReset = true
        let report = FanWriter(smc: smc, discovery: discovery(apple: true)).setAllAuto()
        XCTAssertTrue(report.confirmed)
        XCTAssertFalse(report.requestErrors.isEmpty)
        XCTAssertEqual(smc.values["Ftst"], 0)
        XCTAssertEqual(smc.values["F0Md"], 3)
    }

    func testUnlockResetFailureRemainsUnconfirmedEvenWhenFanModesReadAuto() {
        let smc = FakeSMC(); smc.failedWrites = ["Ftst"]
        let report = FanWriter(smc: smc, discovery: discovery(apple: true)).setAllAuto()
        XCTAssertFalse(report.confirmed)
        XCTAssertTrue(report.unconfirmed.contains { $0.contains("Ftst") })
    }

    func testForceBitResetPreservesUnrelatedBitsAndRejectsInvalidReadback() {
        let smc = FakeSMC(); smc.values["FS! "] = 7
        let writer = FanWriter(smc: smc, discovery: discovery(modes: false, force: true))
        XCTAssertTrue(writer.setAllAuto().confirmed)
        XCTAssertEqual(smc.values["FS! "], 4, "only the discovered fan bits are cleared")
        for value in [Double.nan, Double.infinity, -1, 1.5, 100_000] {
            smc.values["FS! "] = value
            XCTAssertFalse(writer.setAllAuto().confirmed)
        }
    }

    func testUnknownRecoveryReplyNeverDecodesAsEmptyAutomaticPolicies() throws {
        let report = FanAutoRecoveryReport(unconfirmed: ["mode unavailable"], requestErrors: [])
        let data = try FanPolicyReply.encode([:], recovery: report)
        XCTAssertThrowsError(try FanPolicyReply.decode(data))
        XCTAssertThrowsError(try PolicyCoding.decoder().decode([Int: FanPolicy].self, from: data), "older clients must fail closed too")
        let recovered = try FanPolicyReply.encode([:], recovery: .init(unconfirmed: [], requestErrors: ["transient request failure"]))
        XCTAssertEqual(try FanPolicyReply.decode(recovered), [:])
        let desired: [Int: FanPolicy] = [0: .fixed(rpm: 2500)]
        XCTAssertEqual(try FanPolicyReply.decode(FanPolicyReply.encode(desired, recovery: nil)), desired)
    }
}
