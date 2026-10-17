import XCTest
import ThermoKit
@testable import ThermoApp

final class BatteryCareModelTests: XCTestCase {
    @MainActor final class Preference {
        var value: Bool
        init(_ value: Bool = false) { self.value = value }
        var io: BatteryCarePreferences { .init(load: { self.value }, save: { self.value = $0 }) }
    }
    actor Rig {
        var value: BatteryChargeState
        var failRead = false, failEnd = false, failBeforeSend = false, failAfterSend = false
        var starts = 0, stops = 0
        init() { var s = BatteryChargeState(); s.phase = .off; s.gate = .allowed; s.support = .smc; s.percent = 90; s.externalPower = true; value = s }
        nonisolated var backend: BatteryCareBackend { .init(read: { try await self.read() }, set: { try await self.set($0, $1) }, reset: {}) }
        func read() throws -> BatteryChargeState { if failRead { throw BatteryGateError("fixture unavailable") }; return value }
        func set(_ policy: BatteryChargePolicy, _ id: String) throws {
            if failBeforeSend { failRead = true; throw BatteryChargeClientError.notStarted("old helper") }
            if policy == .off {
                stops += 1
                if failEnd { recovering(); throw BatteryGateError("recovery pending") }
                recover(); return
            }
            starts += 1; value.policy = policy; value.sessionID = id; value.ownedByCaller = true
            value.phase = policy == .limit80 ? .holding : .watching
            value.gate = policy == .limit80 ? .inhibited : .allowed
            value.ownership = policy == .limit80 ? .owned : .none
            if failAfterSend { recovering(); throw BatteryGateError("uncertain request") }
        }
        func recovering() { value.policy = .off; value.phase = .recovering; value.ownership = .uncertain; value.ownedByCaller = false; value.sessionID = nil }
        func recover() { failRead = false; failEnd = false; value = BatteryChargeState(); value.phase = .off; value.gate = .allowed; value.support = .smc; value.percent = 90; value.externalPower = true }
        func faults(end: Bool = false, before: Bool = false, after: Bool = false) { failEnd = end; failBeforeSend = before; failAfterSend = after }
        func loseOwnership(sameSession: Bool) { value.ownedByCaller = false; if !sameSession { value.sessionID = UUID().uuidString } }
        func controllerUnavailable() { value = BatteryChargeState(); value.error = "initialization failed" }
        func reading(_ percent: Double, plugged: Bool) { value.percent = percent; value.externalPower = plugged }
    }
    @MainActor func settle(_ model: BatteryCareModel) async {
        for _ in 0..<200 { if !model.busy { return }; try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("model remained busy")
    }
    @MainActor func testOpeningPanelOnlyReadsEvenWhenStartupPreferenceIsEnabled() async {
        let rig = Rig(), pref = Preference(true), model = BatteryCareModel(backend: rig.backend, preferences: pref.io, exit: {})
        model.open(); await settle(model)
        let starts = await rig.starts; XCTAssertEqual(starts, 0); XCTAssertFalse(model.needsQuitRecovery); XCTAssertTrue(model.canEnable)
        model.close()
    }
    @MainActor func testSavedPreferenceResumesOnlyThroughExplicitLaunchHook() async {
        let rig = Rig(), pref = Preference(true), model = BatteryCareModel(backend: rig.backend, preferences: pref.io, exit: {})
        model.restoreSavedPreference(); await settle(model); XCTAssertTrue(model.needsQuitRecovery)
        model.restoreSavedPreference(); let starts = await rig.starts; XCTAssertEqual(starts, 1)
        model.change(.chargeToFull); await settle(model); XCTAssertEqual(model.state?.policy, .chargeToFull); XCTAssertTrue(pref.value)
        model.change(.off); await settle(model); XCTAssertFalse(pref.value); XCTAssertFalse(model.needsQuitRecovery)
    }
    @MainActor func testLaunchPreferenceWaitsForAnAlreadyRunningPanelQuery() async {
        let rig = Rig(), model = BatteryCareModel(backend: rig.backend, preferences: Preference(true).io, exit: {})
        model.open(); model.restoreSavedPreference(); await settle(model)
        let starts = await rig.starts; XCTAssertEqual(starts, 1); XCTAssertTrue(model.needsQuitRecovery)
        model.change(.off); await settle(model); model.close()
    }
    @MainActor func testQuitBlocksUntilRecoveryAndKeepsStartupPreference() async {
        let rig = Rig(), pref = Preference(); var exits = 0
        let model = BatteryCareModel(backend: rig.backend, preferences: pref.io, exit: { exits += 1 })
        model.open(); await settle(model); model.change(.limit80); await settle(model)
        await rig.faults(end: true)
        XCTAssertTrue(model.requestQuit()); await settle(model)
        XCTAssertEqual(exits, 0); XCTAssertTrue(model.needsQuitRecovery); XCTAssertTrue(pref.value)
        await rig.recover(); model.refresh(); await settle(model)
        XCTAssertEqual(exits, 1); XCTAssertFalse(model.needsQuitRecovery); XCTAssertTrue(pref.value)
        model.refresh(); await settle(model); XCTAssertEqual(exits, 1); model.close()
    }
    @MainActor func testUncertainRequestAndUnavailableControllerCannotClaimRecovery() async {
        let rig = Rig(), model = BatteryCareModel(backend: rig.backend, preferences: Preference().io, exit: {})
        model.open(); await settle(model); await rig.faults(after: true)
        model.change(.limit80); await settle(model); XCTAssertTrue(model.needsQuitRecovery)
        await rig.controllerUnavailable(); model.refresh(); await settle(model)
        XCTAssertEqual(model.state?.phase, .blocked); XCTAssertTrue(model.needsQuitRecovery)
        await rig.recover(); model.refresh(); await settle(model); XCTAssertFalse(model.needsQuitRecovery); model.close()
    }
    @MainActor func testKnownPreflightFailureDoesNotTrapExit() async {
        let rig = Rig(), model = BatteryCareModel(backend: rig.backend, preferences: Preference().io, exit: {})
        model.open(); await settle(model); await rig.faults(before: true)
        model.change(.limit80); await settle(model)
        XCTAssertNil(model.state); XCTAssertFalse(model.needsQuitRecovery); XCTAssertFalse(model.requestQuit()); XCTAssertNotNil(model.issue); model.close()
    }
    @MainActor func testSameSessionLostConnectionStaysPendingButForeignSessionIsNotStopped() async {
        let rig = Rig(), pref = Preference(), model = BatteryCareModel(backend: rig.backend, preferences: pref.io, exit: {})
        model.open(); await settle(model); model.change(.limit80); await settle(model)
        await rig.loseOwnership(sameSession: true); model.refresh(); await settle(model); XCTAssertTrue(model.needsQuitRecovery)
        await rig.loseOwnership(sameSession: false); model.refresh(); await settle(model)
        XCTAssertFalse(model.needsQuitRecovery); XCTAssertTrue(model.anotherOwner); XCTAssertFalse(model.canStop)
        model.change(.off); XCTAssertFalse(pref.value) // Only the saved preference is changed.
        let stops = await rig.stops; XCTAssertEqual(stops, 0); model.close()
    }
    @MainActor func testCorruptDefaultsCannotEnableChargingAndCanBeExplicitlyDisabled() async throws {
        let suite = "thermo-battery-model-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BatteryCarePreferences.defaults(defaults)
        for value: Any in ["true", 1, [true], "limit80"] { defaults.set(value, forKey: BatteryCarePreferences.key); XCTAssertFalse(preferences.load()) }
        preferences.save(true); XCTAssertTrue(preferences.load())
        let model = BatteryCareModel(backend: Rig().backend, preferences: preferences, exit: {})
        model.change(.off); XCTAssertFalse(preferences.load()); XCTAssertFalse(model.busy)
    }
    @MainActor func testQuitCannotBypassHistoryFlushFence() async {
        let rig = Rig(), entered = expectation(description: "history flush"), gate = AWDLModelTests.FlushGate(entered)
        var backend = rig.backend; backend.flush = { await gate.wait() }; var exits = 0
        let model = BatteryCareModel(backend: backend, preferences: Preference().io, exit: { exits += 1 })
        model.open(); await settle(model); model.change(.limit80); await settle(model)
        XCTAssertTrue(model.requestQuit()); await fulfillment(of: [entered], timeout: 3)
        XCTAssertTrue(model.busy); XCTAssertFalse(model.needsQuitRecovery); XCTAssertTrue(model.requestQuit()); XCTAssertEqual(exits, 0)
        await gate.release(); await settle(model); XCTAssertEqual(exits, 1); model.close()
    }
    @MainActor func testQuitDuringStartupReadCancelsDeferredAutomaticEnable() async {
        let rig = Rig(), entered = expectation(description: "startup read"), gate = AWDLModelTests.FlushGate(entered)
        var backend = rig.backend; backend.read = { await gate.wait(); return try await rig.read() }
        let model = BatteryCareModel(backend: backend, preferences: Preference(true).io, exit: {})
        model.restoreSavedPreference(); await fulfillment(of: [entered], timeout: 3)
        XCTAssertFalse(model.requestQuit())
        await gate.release(); await settle(model)
        let starts = await rig.starts; XCTAssertEqual(starts, 0); XCTAssertFalse(model.needsQuitRecovery)
    }
    @MainActor func testAutonomousRecoveryClearsPreviousFailureBeforeExit() async {
        let rig = Rig(), exited = expectation(description: "poll confirmed recovery")
        let model = BatteryCareModel(backend: rig.backend, preferences: Preference().io, exit: { exited.fulfill() })
        model.open(); await settle(model); model.change(.limit80); await settle(model)
        await rig.faults(end: true); XCTAssertTrue(model.requestQuit()); await settle(model); XCTAssertNotNil(model.issue)
        await rig.recover(); await fulfillment(of: [exited], timeout: 3)
        XCTAssertNil(model.issue); XCTAssertFalse(model.needsQuitRecovery); model.close()
    }
    @MainActor func testReadOnlyNativeFallbackDoesNotCertifyAnOwnedSessionHasRecovered() async {
        let rig = Rig()
        var backend = rig.backend
        backend.probe = { BatteryChargeProbe.capture(io: .init(info: { _ in nil }, read: { _ in throw BatteryGateError("not present") }, write: { _, _ in XCTFail("probe cannot write") }), presence: .present, nativeEligible: true) }
        let model = BatteryCareModel(backend: backend, preferences: Preference().io, exit: {})
        model.open(); await settle(model); model.change(.limit80); await settle(model)
        await rig.faults(before: true); model.change(.chargeToFull); await settle(model)
        XCTAssertNil(model.state); XCTAssertEqual(model.probe?.support, .systemSettings)
        XCTAssertTrue(model.needsQuitRecovery); XCTAssertFalse(model.canEnable)
        await rig.recover(); model.refresh(); await settle(model); XCTAssertFalse(model.needsQuitRecovery); model.close()
    }
    @MainActor func testFullChargeButtonMatchesACPercentAndExistingLimitRequirements() async {
        let rig = Rig(), model = BatteryCareModel(backend: rig.backend, preferences: Preference().io, exit: {})
        model.open(); await settle(model); XCTAssertFalse(model.canChargeToFull)
        model.change(.limit80); await settle(model); XCTAssertTrue(model.canChargeToFull)
        await rig.reading(100, plugged: true); model.refresh(); await settle(model); XCTAssertFalse(model.canChargeToFull)
        let before = await rig.starts; model.change(.chargeToFull); let after = await rig.starts; XCTAssertEqual(before, after)
        await rig.reading(90, plugged: false); model.refresh(); await settle(model); XCTAssertFalse(model.canChargeToFull)
        await rig.reading(90, plugged: true); model.refresh(); await settle(model); XCTAssertTrue(model.canChargeToFull)
        model.change(.chargeToFull); await settle(model); XCTAssertFalse(model.canChargeToFull)
        model.change(.off); await settle(model); model.close()
    }
}
