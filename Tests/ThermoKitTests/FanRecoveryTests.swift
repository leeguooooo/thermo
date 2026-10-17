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
        var quantizeTargets = false
        var ignoredManualModeAttempts = 0
        var ignoredTargetAttempts = 0
        func double(_ key: FourCC) throws -> Double {
            guard !failedReads.contains(key), let value = values[key] else { throw Fault.injected }
            return value
        }
        func write(_ key: FourCC, value: Double) throws {
            writes.append((key, value))
            if failedWrites.contains(key) { throw Fault.injected }
            if key == "F0Md", value == 1, ignoredManualModeAttempts > 0 { ignoredManualModeAttempts -= 1; return }
            if key == "F0Tg", ignoredTargetAttempts > 0 { ignoredTargetAttempts -= 1; return }
            if !ignoredWrites.contains(key) { values[key] = value }
            if quantizeTargets, key == "F0Tg" { values[key] = value.rounded(.down) }
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

    func testAutomaticRecoveryRequiresBothModeAndForceFlagsWhenBothExist() {
        let smc = FakeSMC()
        let writer = FanWriter(smc: smc, discovery: discovery(force: true))
        smc.ignoredWrites = ["FS! "]
        XCTAssertFalse(writer.setAllAuto().confirmed, "mode zero cannot override an uncleared force bit")
        smc.ignoredWrites = []; smc.failedWrites = ["F0Md"]; smc.values["F0Md"] = 1
        XCTAssertFalse(writer.setAllAuto().confirmed)
        XCTAssertEqual(smc.values["FS! "], 0, "still attempt the force reset when mode writing fails")
        smc.failedWrites = []
        XCTAssertTrue(writer.setAllAuto().confirmed)
    }

    func testUnexpectedOriginalModeIsNotRestoredOrCertifiedAsAutomatic() {
        let smc = FakeSMC(); smc.values["F0Md"] = 2
        let writer = FanWriter(smc: smc, discovery: discovery())
        smc.ignoredWrites = ["F0Md"]
        XCTAssertFalse(writer.setAllAuto().confirmed)
        smc.ignoredWrites = []
        XCTAssertTrue(writer.setAllAuto().confirmed)
        XCTAssertEqual(smc.values["F0Md"], 0)
        smc.values["F0Md"] = 3
        let previouslyThree = FanWriter(smc: smc, discovery: discovery())
        smc.values["F0Md"] = 0; smc.ignoredWrites = ["F0Md"]
        XCTAssertTrue(previouslyThree.setAllAuto().confirmed, "both known system modes remain automatic even if firmware transitions between them")
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

    func manualSMC() -> FakeSMC {
        let smc = FakeSMC()
        smc.values["F0Mn"] = 1200; smc.values["F0Mx"] = 6000
        smc.values["F0Tg"] = 1400; smc.values["F0Md"] = 0
        smc.values["Ftst"] = 0; smc.values["FS! "] = 4
        return smc
    }

    func testManualClampsAndConfirmsQuantizedTargetWithoutRewritingDuringVerification() throws {
        let smc = manualSMC(); smc.quantizeTargets = true
        let writer = FanWriter(smc: smc, discovery: discovery())
        XCTAssertEqual(try writer.setManual(0, rpm: 2500.75), 2500)
        XCTAssertEqual(try writer.setManual(0, rpm: 0), 1200)
        XCTAssertEqual(try writer.setManual(0, rpm: .infinity), 6000)
        let count = smc.writes.count
        XCTAssertEqual(try writer.verifyManual(0, rpm: 6000), 6000)
        XCTAssertEqual(smc.writes.count, count)
        smc.values["F0Md"] = 0
        XCTAssertThrowsError(try writer.verifyManual(0, rpm: 6000), "firmware reclaim must not be hidden by hysteresis")
    }

    func testAcknowledgedModeAndTargetWritesMustEventuallyReadBackBeforeSuccess() throws {
        for apple in [false, true] {
            let smc = manualSMC(); smc.ignoredManualModeAttempts = 2; smc.ignoredTargetAttempts = 3
            let writer = FanWriter(smc: smc, discovery: discovery(apple: apple))
            XCTAssertEqual(try writer.setManual(0, rpm: 2500), 2500)
            XCTAssertEqual(smc.values["F0Md"], 1); XCTAssertEqual(smc.values["F0Tg"], 2500)
            XCTAssertGreaterThan(smc.writes.filter { $0.0 == "F0Md" && $0.1 == 1 }.count, 2)
            let writes = smc.writes.count
            smc.values["F0Md"] = 0
            XCTAssertThrowsError(try writer.verifyManual(0, rpm: 2500))
            XCTAssertEqual(smc.writes.count, writes, "firmware reclaim during monitoring must not cause a retry/write")
        }
    }

    func testManualRejectsInvalidLimitsAndRequestsBeforeAnyWrite() {
        for (lo, hi) in [(Double.nan, 6000.0), (1200, Double.infinity), (-1, 6000), (6000, 1200), (0, 0)] {
            let smc = manualSMC(); smc.values["F0Mn"] = lo; smc.values["F0Mx"] = hi
            XCTAssertThrowsError(try FanWriter(smc: smc, discovery: discovery()).setManual(0, rpm: 2500))
            XCTAssertTrue(smc.writes.isEmpty)
        }
        for rpm in [Double.nan, -Double.infinity, -1] {
            let smc = manualSMC()
            XCTAssertThrowsError(try FanWriter(smc: smc, discovery: discovery()).setManual(0, rpm: rpm))
            XCTAssertTrue(smc.writes.isEmpty)
        }
        let smc = manualSMC()
        XCTAssertThrowsError(try FanWriter(smc: smc, discovery: discovery(modes: false)).setManual(0, rpm: 2500))
        XCTAssertTrue(smc.writes.isEmpty)
    }

    func testManualRejectsIgnoredModeTargetAndUnreadableTargets() {
        for ignored: FourCC in ["F0Md", "F0Tg"] {
            let smc = manualSMC(); smc.ignoredWrites = [ignored]
            XCTAssertThrowsError(try FanWriter(smc: smc, discovery: discovery()).setManual(0, rpm: 2500))
        }
        let smc = manualSMC(); smc.failedReads = ["F0Tg"]
        XCTAssertThrowsError(try FanWriter(smc: smc, discovery: discovery()).setManual(0, rpm: 2500))
        smc.failedReads = []
        let writer = FanWriter(smc: smc, discovery: discovery())
        for actual in [Double.nan, Double.infinity, -1, 2498] {
            smc.values["F0Md"] = 1; smc.values["F0Tg"] = actual
            XCTAssertThrowsError(try writer.verifyManual(0, rpm: 2500))
        }
    }

    func testManualUnlockMustBeObservedAndRecheckedAfterFirmwareReclaimsIt() throws {
        let smc = manualSMC(); smc.ignoredWrites = ["Ftst"]
        let writer = FanWriter(smc: smc, discovery: discovery(apple: true))
        XCTAssertThrowsError(try writer.setManual(0, rpm: 2500))
        XCTAssertEqual(smc.writes.count, 1, "do not write mode/target without unlock confirmation")
        smc.ignoredWrites = []
        XCTAssertEqual(try writer.setManual(0, rpm: 2500), 2500)
        smc.values["Ftst"] = 0
        XCTAssertThrowsError(try writer.verifyManual(0, rpm: 2500))
        XCTAssertEqual(try writer.setManual(0, rpm: 2500), 2500, "unlock cache must be invalidated")
    }

    func testLastObservedAutomaticFanReleasesUnlockButMixedManualFanKeepsIt() throws {
        let smc = manualSMC(); smc.values["F1Md"] = 0
        smc.values["F1Mn"] = 1200; smc.values["F1Mx"] = 6000
        let writer = FanWriter(smc: smc, discovery: discovery(apple: true))
        try writer.setManual(0, rpm: 2500); try writer.setManual(1, rpm: 3000)
        try writer.setAuto(0)
        XCTAssertEqual(smc.values["Ftst"], 1, "do not revoke the other fan's manual ownership")
        smc.firmwareOnUnlockReset = true
        try writer.setAuto(1)
        XCTAssertEqual(smc.values["Ftst"], 0)
        XCTAssertTrue(writer.setAllAuto().confirmed)
        try writer.setManual(0, rpm: 2500)
        smc.ignoredWrites = ["Ftst"]
        XCTAssertThrowsError(try writer.setAuto(0), "mode readbacks alone do not confirm release of the final unlock")
    }

    func testManualForceBitsPreserveOtherFansAndRequireReadback() throws {
        let smc = manualSMC()
        let writer = FanWriter(smc: smc, discovery: discovery(modes: false, force: true))
        XCTAssertEqual(try writer.setManual(0, rpm: 2500), 2500)
        XCTAssertEqual(smc.values["FS! "], 5)
        smc.values["FS! "] = 4; smc.ignoredWrites = ["FS! "]
        XCTAssertThrowsError(try writer.setManual(0, rpm: 2500))
    }

    func testControlFaultReplyRemainsUnknownEvenAfterAutomaticRecoveryConfirmed() throws {
        let data = try FanPolicyReply.encode([0: .fixed(rpm: 2500)], recovery: .init(unconfirmed: [], requestErrors: []), controlError: "target write failed")
        XCTAssertThrowsError(try FanPolicyReply.decode(data))
        XCTAssertThrowsError(try PolicyCoding.decoder().decode([Int: FanPolicy].self, from: data))
    }
}
