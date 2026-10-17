import XCTest
import ThermoKit
@testable import thermo

final class ChargeTests: XCTestCase {
    func request(_ parts: [String]) throws -> ChargeRequest {
        let args = try Args(["charge"] + parts)
        return try .init(Array(args.positionals.dropFirst()), args: args)
    }
    func testReadOnlyProbeAndPreviewAreExplicit() throws {
        XCTAssertEqual(try request([]), .status(probe: false))
        XCTAssertEqual(try request(["status", "--probe", "--json"]), .status(probe: true))
        XCTAssertEqual(try request(["limit80", "--dry-run"]), .hold(.limit80, preview: true))
        XCTAssertEqual(try request(["full"]), .hold(.chargeToFull, preview: false))
        XCTAssertEqual(try request(["recover"]), .recover)
        let data = try JSONEncoder().encode(ChargePlan(policy: .limit80)), row = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(row["pauseAtPercent"] as? Int, 80); XCTAssertEqual(row["resumeBelowPercent"] as? Int, 75)
        XCTAssertEqual(row["changesMade"] as? Bool, false); XCTAssertEqual(row["forcesCharging"] as? Bool, false)
    }
    func testInvalidOrMisplacedControlsFailBeforeHelperUse() {
        for args in [["off"], ["limit80", "--probe"], ["full", "--seconds", "60"], ["status", "--dry-run"], ["recover", "--probe"], ["status", "extra"], ["full", "--csv"], ["full", "--yes"], ["limit80", "--permanent"]] {
            XCTAssertThrowsError(try request(args), args.joined(separator: " "))
        }
    }
    func testDryRunCreatesNoBackendAndDoesNotProbeHardware() throws {
        let args = try Args(["charge", "limit80", "--dry-run", "--json"])
        try ChargeCommand(app: App(args: args), makeBackend: { XCTFail("dry-run backend"); return Rig().backend }, probe: {
            XCTFail("dry-run probe")
            return BatteryChargeProbe.capture(io: .init(info: { _ in nil }, read: { _ in throw BatteryGateError("fixture") }, write: { _, _ in XCTFail("probe write") }), presence: .unknown, nativeEligible: false)
        }).run(["limit80"])
    }
    final class Rig {
        var state: BatteryChargeState
        var actions: [BatteryChargePolicy] = [], resets = 0, reads = 0, interrupted = false
        var failBefore = false, failAfter = false, failRestore = false, failRestoreBeforeSend = false
        var afterRead: (() -> Void)?
        init() { state = .init(); state.phase = .off; state.gate = .allowed }
        var backend: ChargeBackend { .init(read: {
            self.reads += 1; let value = self.state; self.afterRead?(); return value
        }, set: { policy, id in
            if self.failBefore { throw BatteryChargeClientError.notStarted("old helper") }
            self.actions.append(policy)
            if policy == .off {
                if self.failRestoreBeforeSend { throw BatteryChargeClientError.notStarted("helper changed during active session") }
                if self.failRestore { self.state.phase = .recovering; self.state.policy = .off; self.state.ownership = .uncertain; self.state.ownedByCaller = false; self.state.sessionID = nil; throw BatteryGateError("restore failed") }
                self.state = .init(); self.state.phase = .off; self.state.gate = .allowed
            } else {
                self.state.policy = policy; self.state.phase = policy == .limit80 ? .holding : .watching; self.state.gate = policy == .limit80 ? .inhibited : .allowed; self.state.ownership = policy == .limit80 ? .owned : .none; self.state.ownedByCaller = true; self.state.sessionID = id
                if self.failAfter { throw BatteryGateError("reply uncertain") }
            }
        }, reset: { self.resets += 1 }) }
        func run(_ policy: BatteryChargePolicy = .limit80, emit: (BatteryChargeState) throws -> Void = { _ in }) throws {
            try ChargeForegroundSession(backend: backend).run(policy: policy, interrupted: { self.interrupted }, wait: { self.interrupted = true }, emit: emit)
        }
    }
    func testInterruptRestoresAndConfirmsBeforeReturn() throws {
        let rig = Rig(); var emitted: [BatteryChargeState.Phase] = []
        try rig.run { emitted.append($0.phase) }
        XCTAssertEqual(rig.actions, [.limit80, .off]); XCTAssertEqual(emitted, [.holding, .off]); XCTAssertEqual(rig.resets, 1)
    }
    func testPreflightFailureDoesNotSendRecoveryOrQueryState() {
        let rig = Rig(); rig.failBefore = true
        XCTAssertThrowsError(try rig.run()); XCTAssertTrue(rig.actions.isEmpty); XCTAssertEqual(rig.reads, 0); XCTAssertEqual(rig.resets, 1)
    }
    func testUncertainBeginCleansUpOnlyAnOwnedMatchingSession() {
        let rig = Rig(); rig.failAfter = true
        XCTAssertThrowsError(try rig.run()); XCTAssertEqual(rig.actions, [.limit80, .off]); XCTAssertTrue(ChargeForegroundSession.ended(rig.state)); XCTAssertEqual(rig.resets, 1)
    }
    func testForeignSessionIsObservedButNeverStopped() throws {
        let rig = Rig()
        rig.afterRead = { rig.state.sessionID = UUID().uuidString; rig.state.ownedByCaller = false }
        // First iteration sees our snapshot; the next read sees a different owner.
        try ChargeForegroundSession(backend: rig.backend).run(policy: .limit80, interrupted: { false }, wait: {}, emit: { _ in })
        XCTAssertEqual(rig.actions, [.limit80]); XCTAssertEqual(rig.resets, 1)
    }
    func testUnconfirmedRecoveryCannotReturnSuccess() {
        let rig = Rig(); rig.failRestore = true
        XCTAssertThrowsError(try rig.run()) { XCTAssertTrue($0.localizedDescription.contains("unconfirmed")) }
        XCTAssertEqual(rig.actions, [.limit80, .off]); XCTAssertEqual(rig.state.phase, .recovering); XCTAssertEqual(rig.resets, 1)
    }
    func testOutputFailureStillRecoversBeforeError() {
        let rig = Rig()
        XCTAssertThrowsError(try rig.run(emit: { _ in throw BatteryGateError("output failed") }))
        XCTAssertEqual(rig.actions, [.limit80, .off]); XCTAssertTrue(ChargeForegroundSession.ended(rig.state))
    }
    func testAlreadyInterruptedRequestNeverChangesPolicy() throws {
        let rig = Rig(); rig.interrupted = true
        try rig.run(); XCTAssertTrue(rig.actions.isEmpty); XCTAssertEqual(rig.resets, 1)
    }
    func testFullChargeIsAnAllowPolicyAndNotAnInhibitRequest() throws {
        let rig = Rig(); var observed: BatteryChargePolicy.Gate?
        try rig.run(.chargeToFull) { if $0.policy == .chargeToFull { observed = $0.gate } }
        XCTAssertEqual(rig.actions, [.chargeToFull, .off]); XCTAssertEqual(observed, .allowed)
    }
    func testPreflightFailureDuringStopStillReportsUnconfirmedRecovery() {
        let rig = Rig(); rig.failRestoreBeforeSend = true
        XCTAssertThrowsError(try rig.run()) { XCTAssertTrue($0.localizedDescription.contains("unconfirmed")) }
        XCTAssertEqual(rig.state.phase, .holding); XCTAssertEqual(rig.resets, 1)
    }
    func testForegroundValidationDistinguishesRefusedAndUnconfirmed() {
        var state = BatteryChargeState(); state.phase = .off; state.gate = .allowed; state.support = .smc; state.percent = 50; state.externalPower = false
        XCTAssertNoThrow(try ChargeCommand.validateStart(state))
        state.phase = .recovering; state.ownership = .uncertain
        XCTAssertThrowsError(try ChargeCommand.validateStart(state)) { XCTAssertEqual(($0 as? CLIError)?.exitCode, 3) }
        state.phase = .off; state.ownership = .none; state.support = .noInternalBattery
        XCTAssertThrowsError(try ChargeCommand.validateStart(state)) { XCTAssertEqual(($0 as? CLIError)?.exitCode, 2) }
        state.support = .smc; state.percent = .nan
        XCTAssertThrowsError(try ChargeCommand.validateStart(state))
    }
    func testRecoverRefusesForeignPolicyAndDoesNotSendOff() throws {
        let rig = Rig(); rig.state.policy = .limit80; rig.state.phase = .holding; rig.state.sessionID = UUID().uuidString
        let args = try Args(["charge", "recover", "--json"])
        XCTAssertThrowsError(try ChargeCommand(app: App(args: args), makeBackend: { rig.backend }).run(["recover"])) { XCTAssertEqual(($0 as? CLIError)?.exitCode, 2) }
        XCTAssertTrue(rig.actions.isEmpty); XCTAssertEqual(rig.resets, 1)
    }
    func testRecoveryFailureUsesUnconfirmedExitAndAlreadyEndedIsReadOnly() throws {
        let rig = Rig(); rig.state.phase = .recovering; rig.state.ownership = .uncertain; rig.failRestore = true
        let args = try Args(["charge", "recover", "--json"])
        XCTAssertThrowsError(try ChargeCommand(app: App(args: args), makeBackend: { rig.backend }).run(["recover"])) { XCTAssertEqual(($0 as? CLIError)?.exitCode, 3) }
        let idle = Rig()
        try ChargeCommand(app: App(args: args), makeBackend: { idle.backend }).run(["recover"])
        XCTAssertTrue(idle.actions.isEmpty)
    }
    func testChargeIsIncludedInScopedHelpAndCapabilityContract() throws {
        XCTAssertTrue(CommandHelp.text(for: ["charge", "limit80"]).contains("charge limit80"))
        XCTAssertTrue(CommandHelp.capabilities.contains { $0.command == "charge status" })
        XCTAssertNoThrow(try CommandContract.validate(Args(["charge", "limit80", "--dry-run", "--json"])))
        XCTAssertThrowsError(try CommandContract.validate(Args(["charge", "status", "--dry-run"])))
        XCTAssertThrowsError(try CommandContract.validate(Args(["charge", "full", "--csv"])))
    }
    func testAutomaticFullCompletionEndsWithoutSendingAnotherOffRequest() throws {
        let rig = Rig()
        rig.afterRead = {
            if rig.state.policy == .chargeToFull {
                rig.state = .init(); rig.state.phase = .off; rig.state.gate = .allowed; rig.state.lastFullChargeEndReason = .fullyCharged
            }
        }
        try ChargeForegroundSession(backend: rig.backend).run(policy: .chargeToFull, interrupted: { false }, wait: {}, emit: { _ in })
        XCTAssertEqual(rig.actions, [.chargeToFull]); XCTAssertEqual(rig.resets, 1)
    }
}
