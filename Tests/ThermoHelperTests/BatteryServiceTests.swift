import Foundation
import XCTest
@testable import ThermoKit
@testable import ThermoHelper

/// Matches the protocol-7 selectors, without the new session-ID parameter.
@objc protocol LegacyBatteryHelper {
    func setBatteryChargePolicy(_ policy: String, reply: @escaping (String?) -> Void)
    func batteryChargeState(reply: @escaping (Data) -> Void)
}

final class BatteryServiceTests: XCTestCase {
    private func legacyCall<T: Sendable>(_ connection: NSXPCConnection,
                                        send: (LegacyBatteryHelper, @escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let done: @Sendable (Result<T, Error>) -> Void = { result in once.run { continuation.resume(with: result) } }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ done(.failure($0)) }) as? LegacyBatteryHelper else {
                done(.failure(BatteryGateError("missing legacy proxy"))); return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { done(.failure(BatteryGateError("legacy XPC timed out"))) }
            send(proxy, done)
        }
    }
    final class Rig: @unchecked Sendable {
        let id = UUID().uuidString
        private let lock = NSLock()
        var bytes: [UInt8] = [0, 0, 0, 0]
        var record: BatteryGateRecord?
        var percent: Double? = 90, plugged: Bool? = true
        var now = 100.0, observedAt = 100.0
        var failRestore = false, failHold = false, writes = 0
        var batteryPresence: BatteryPresence = .present, nativeAvailable = false, hasChargeKeys = true
        var changed: (@Sendable ([UInt8]) -> Void)?
        func access<T>(_ body: (Rig) throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body(self) }
        var info: SMCKeyInfo { .init(key: "CHTE", type: "ui32", size: 4, attributes: 0xd4) }
        func controller() -> BatteryChargingGate {
            .init(io: .init(info: { key in self.access { key == "CHTE" && $0.hasChargeKeys ? $0.info : nil } }, read: { _ in
                self.access { .init(key: "CHTE", type: "ui32", bytes: $0.bytes) }
            }, write: { _, value in
                let callback = try self.access { rig -> (@Sendable ([UInt8]) -> Void)? in
                    XCTAssertNotNil(rig.record)
                    if value == [0, 0, 0, 0], rig.failRestore { throw BatteryGateError("restore denied") }
                    if value == [1, 0, 0, 0], rig.failHold { throw BatteryGateError("hold denied") }
                    rig.bytes = value; rig.writes += 1; return rig.changed
                }
                callback?(value)
            }), store: .init(load: { self.access { $0.record } }, save: { value in self.access { XCTAssertNil($0.record); $0.record = value } },
                            clear: { value in self.access { XCTAssertEqual($0.record, value); $0.record = nil } }), hardwareID: { self.id })
        }
        func reading() -> BatteryChargePolicy.Observation? { access { .init(percent: $0.percent, externalPower: $0.plugged, observedAt: $0.observedAt) } }
        func coordinator() -> BatteryHelperCoordinator { .init(make: { self.controller() }, power: { self.reading() }, clock: { self.access { $0.now } }, presence: { self.access { $0.batteryPresence } }, nativeEligible: { self.access { $0.nativeAvailable } }, tickInterval: 0.03) }
    }
    final class Endpoint: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        let listener = NSXPCListener.anonymous(), charging: BatteryHelperCoordinator
        let network: AWDLHelperCoordinator, fans: FanHost
        let lock = NSLock(); var connections: [NSXPCConnection] = []
        init(_ rig: Rig, fanGate: DispatchSemaphore? = nil) {
            charging = rig.coordinator()
            let networkRig = AWDLServiceTests.Rig()
            network = AWDLHelperCoordinator(make: { networkRig.controller() }, tickInterval: 0.03)
            fans = FanHost(make: { _, _ in
                if let fanGate { _ = fanGate.wait(timeout: .now() + 5) }
                throw BatteryGateError("fixture fans unavailable")
            }, fallbackSleep: nil, saveAutomatic: {})
            super.init(); listener.delegate = self; listener.resume()
        }
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
            let service = Service(fans: fans, network: network, charging: charging)
            c.exportedInterface = NSXPCInterface(with: ThermoHelperProtocol.self); c.exportedObject = service
            c.invalidationHandler = { service.disconnected() }; c.interruptionHandler = { service.disconnected() }
            lock.lock(); connections.append(c); lock.unlock(); c.resume(); return true
        }
        func client() -> HelperClient { HelperClient(makeConnection: { NSXPCConnection(listenerEndpoint: self.listener.endpoint) }) }
        func stop() { lock.lock(); let list = connections; connections = []; lock.unlock(); list.forEach { $0.invalidate() }; listener.invalidate() }
    }
    func wait(_ client: HelperClient, _ condition: (BatteryChargeState) -> Bool) async throws -> BatteryChargeState {
        for _ in 0..<100 {
            let state = try await client.batteryChargeState(); if condition(state) { return state }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("charging state did not reach expected condition"); return try await client.batteryChargeState()
    }
    func testPolicyFullChargeAndConnectionOwnershipThroughActualXPC() async throws {
        let rig = Rig(), endpoint = Endpoint(rig); defer { endpoint.stop() }
        let first = endpoint.client(), other = endpoint.client(); defer { first.reset(); other.reset() }
        try await first.setBatteryChargePolicy(.limit80)
        let active = try await first.batteryChargeState(); XCTAssertEqual(active.phase, .holding); XCTAssertTrue(active.ownedByCaller)
        let observed = try await other.batteryChargeState(); XCTAssertFalse(observed.ownedByCaller)
        do { try await other.setBatteryChargePolicy(.off); XCTFail("foreign connection") } catch {}
        try await first.setBatteryChargePolicy(.chargeToFull)
        XCTAssertEqual(rig.access { $0.bytes }, [0, 0, 0, 0]); XCTAssertNil(rig.access { $0.record })
        try await first.setBatteryChargePolicy(.limit80); try await first.setBatteryChargePolicy(.off)
        let off = try await first.batteryChargeState(); XCTAssertEqual(off.policy, .off); XCTAssertFalse(off.ownedByCaller)
    }
    func testDisconnectRestoresWithoutAnotherClientSendingAnOffRequest() async throws {
        let rig = Rig(), endpoint = Endpoint(rig); defer { endpoint.stop() }
        let first = endpoint.client(), observer = endpoint.client(); defer { observer.reset() }
        try await first.setBatteryChargePolicy(.limit80); first.reset()
        _ = try await wait(observer) { $0.phase == .off && $0.policy == .off }
        XCTAssertNil(rig.access { $0.record }); XCTAssertEqual(rig.access { $0.bytes }, [0, 0, 0, 0])
    }
    func testTimerAppliesThresholdWithoutStatePolling() async throws {
        let rig = Rig(); rig.access { $0.percent = 79 }
        let endpoint = Endpoint(rig); defer { endpoint.stop() }; let client = endpoint.client(); defer { client.reset() }
        try await client.setBatteryChargePolicy(.limit80)
        let applied = expectation(description: "autonomous charging timer")
        rig.access { $0.changed = { value in if value == [1, 0, 0, 0] { applied.fulfill() } }; $0.percent = 80 }
        await fulfillment(of: [applied], timeout: 3)
        rig.access { $0.changed = nil; $0.percent = 74 }
        _ = try await wait(client) { $0.phase == .watching }
        XCTAssertNil(rig.access { $0.record })
    }
    func testFailedDisconnectRecoveryRetainsRecordAndTimerRetries() async throws {
        let rig = Rig(), endpoint = Endpoint(rig); defer { endpoint.stop() }
        let first = endpoint.client(), observer = endpoint.client(); defer { observer.reset() }
        try await first.setBatteryChargePolicy(.limit80); rig.access { $0.failRestore = true }; first.reset()
        _ = try await wait(observer) { $0.phase == .recovering }
        XCTAssertNotNil(rig.access { $0.record }); rig.access { $0.failRestore = false }
        _ = try await wait(observer) { $0.phase == .off }; XCTAssertNil(rig.access { $0.record })
    }
    func testRemovalFanoutRestoresChargingAndKeepsFailedPreparationFenced() async throws {
        let rig = Rig(), endpoint = Endpoint(rig); defer { endpoint.stop() }; let client = endpoint.client(); defer { client.reset() }
        try await client.setBatteryChargePolicy(.limit80)
        let token = UUID().uuidString
        do { try await client.prepareRemoval(true, token: token); XCTFail("unverified fans") } catch {}
        XCTAssertNil(rig.access { $0.record }); XCTAssertEqual(rig.access { $0.bytes }, [0, 0, 0, 0])
        do { try await client.setBatteryChargePolicy(.limit80); XCTFail("removal fence") } catch {}
        try await client.prepareRemoval(false, token: token); try await client.setBatteryChargePolicy(.limit80)
    }
    func testBlockedFansDoNotBlockStartupChargingRecovery() async throws {
        let rig = Rig(), fanGate = DispatchSemaphore(value: 0)
        rig.access { $0.bytes = [1, 0, 0, 0]; $0.record = .init(hardwareID: $0.id, layout: .chte, registers: [$0.info]) }
        let endpoint = Endpoint(rig, fanGate: fanGate); defer { fanGate.signal(); endpoint.stop() }
        let client = endpoint.client(); defer { client.reset() }
        let state = try await client.batteryChargeState(); XCTAssertEqual(state.phase, .off)
        XCTAssertNil(rig.access { $0.record }); XCTAssertEqual(rig.access { $0.bytes }, [0, 0, 0, 0])
    }
    func testClosedOwnerQueuedBehindStartupCannotActivate() async {
        let rig = Rig(), gate = DispatchSemaphore(value: 0), owner = AWDLConnectionOwner()
        let manager = BatteryHelperCoordinator(make: { _ = gate.wait(timeout: .now() + 5); return rig.controller() }, power: { rig.reading() }, presence: { .present }, nativeEligible: { false }, tickInterval: 0.03)
        let rejected = expectation(description: "closed owner rejected")
        manager.setPolicy(.limit80, owner: owner) { error in XCTAssertNotNil(error); rejected.fulfill() }
        manager.disconnected(owner: owner); gate.signal()
        await fulfillment(of: [rejected], timeout: 3); XCTAssertEqual(rig.access { $0.writes }, 0)
    }
    func testOwnerClosingWhilePowerReadIsBlockedCannotWrite() async {
        let rig = Rig(), entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), owner = AWDLConnectionOwner()
        let manager = BatteryHelperCoordinator(make: { rig.controller() }, power: {
            entered.signal(); _ = resume.wait(timeout: .now() + 5); return rig.reading()
        }, clock: { 100 }, presence: { .present }, nativeEligible: { false }, tickInterval: 1)
        let rejected = expectation(description: "close before write")
        manager.setPolicy(.limit80, owner: owner) { error in XCTAssertNotNil(error); rejected.fulfill() }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        owner.close(); resume.signal()
        await fulfillment(of: [rejected], timeout: 3); XCTAssertEqual(rig.access { $0.writes }, 0)
    }
    func testShutdownRequiresConfirmedRecoveryAndRejectsFurtherPolicies() async throws {
        let rig = Rig(), endpoint = Endpoint(rig); defer { endpoint.stop() }; let client = endpoint.client(); defer { client.reset() }
        try await client.setBatteryChargePolicy(.limit80); rig.access { $0.failRestore = true }
        let stopped = expectation(description: "shutdown reports pending")
        endpoint.charging.shutdown(reason: "fixture update") { ok in XCTAssertFalse(ok); stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 3)
        do { try await client.setBatteryChargePolicy(.limit80); XCTFail("stopping") } catch {}
        XCTAssertNotNil(rig.access { $0.record }); rig.access { $0.failRestore = false }
        _ = try await wait(client) { $0.phase == .off }; XCTAssertNil(rig.access { $0.record })
    }
    func testMissingPowerAndSleepGapReleaseHoldBeforePolicyCanResume() async throws {
        let rig = Rig(), endpoint = Endpoint(rig); defer { endpoint.stop() }; let client = endpoint.client(); defer { client.reset() }
        try await client.setBatteryChargePolicy(.limit80)
        rig.access { $0.plugged = nil }
        _ = try await wait(client) { $0.phase == .blocked }; XCTAssertNil(rig.access { $0.record })
        rig.access { $0.plugged = true }
        _ = try await wait(client) { $0.phase == .holding }
        rig.access { $0.now = 131 } // A stale registry sample must not re-acquire after the gap.
        _ = try await wait(client) { $0.phase == .blocked }; XCTAssertNil(rig.access { $0.record })
        rig.access { $0.observedAt = 131; $0.percent = 74 }
        _ = try await wait(client) { $0.phase == .watching }
    }
    func testFailedManualHoldCannotAutomaticallyRetryOnTimer() async throws {
        let rig = Rig(); rig.access { $0.failHold = true }
        let endpoint = Endpoint(rig); defer { endpoint.stop() }; let client = endpoint.client(); defer { client.reset() }
        do { try await client.setBatteryChargePolicy(.limit80); XCTFail("write failed") } catch {}
        let count = rig.access { $0.writes }; rig.access { $0.failHold = false }
        try await Task.sleep(nanoseconds: 120_000_000)
        let state = try await client.batteryChargeState(); XCTAssertEqual(state.policy, .off)
        XCTAssertEqual(rig.access { $0.writes }, count); XCTAssertNil(rig.access { $0.record })
    }
    func testFullChargeNeverOverridesExternalHold() async throws {
        let rig = Rig(); rig.access { $0.bytes = [1, 0, 0, 0] }
        let endpoint = Endpoint(rig); defer { endpoint.stop() }; let client = endpoint.client(); defer { client.reset() }
        try await client.setBatteryChargePolicy(.chargeToFull)
        let state = try await client.batteryChargeState()
        XCTAssertEqual(state.phase, .blocked); XCTAssertEqual(state.ownership, .none); XCTAssertNotNil(state.error)
        XCTAssertEqual(rig.access { $0.writes }, 0)
    }
    func testPowerParserPreservesUnknownExternalSupply() {
        for value: Any in ["yes", NSNumber(value: -1), NSNumber(value: 2), NSNumber(value: Double.nan)] {
            XCTAssertNil(BatteryChargeSystem.parsePower(["ExternalConnected": value], now: 100).externalPower)
        }
        XCTAssertNil(BatteryChargeSystem.parsePower([:], now: 100).externalPower)
        XCTAssertEqual(BatteryChargeSystem.parsePower(["ExternalConnected": true], now: 100).externalPower, true)
        XCTAssertEqual(BatteryChargeSystem.parsePower(["ExternalConnected": 0], now: 100).externalPower, false)
    }
    func testNoInternalBatteryCannotAcquirePolicyEvenWithReadableRegisters() async throws {
        let rig = Rig(); rig.access { $0.batteryPresence = .notObserved }
        let endpoint = Endpoint(rig); defer { endpoint.stop() }; let client = endpoint.client(); defer { client.reset() }
        let state = try await client.batteryChargeState(); XCTAssertEqual(state.support, .noInternalBattery)
        XCTAssertNil(state.percent); XCTAssertNil(state.externalPower)
        do { try await client.setBatteryChargePolicy(.limit80); XCTFail("no internal battery") } catch {}
        XCTAssertEqual(rig.access { $0.writes }, 0); XCTAssertNil(rig.access { $0.record })
    }
    func testUnsupportedSMCOffersNativeSettingsWithoutAnyWrite() async throws {
        let rig = Rig(); rig.access { $0.hasChargeKeys = false; $0.nativeAvailable = true }
        let endpoint = Endpoint(rig); defer { endpoint.stop() }; let client = endpoint.client(); defer { client.reset() }
        let state = try await client.batteryChargeState(); XCTAssertEqual(state.support, .systemSettings)
        do { try await client.setBatteryChargePolicy(.chargeToFull); XCTFail("native settings are not a write API") } catch {}
        XCTAssertEqual(rig.access { $0.writes }, 0)
    }
    func testLosingConfirmedBatteryPresenceRestoresExistingHold() async throws {
        let rig = Rig(), endpoint = Endpoint(rig); defer { endpoint.stop() }; let client = endpoint.client(); defer { client.reset() }
        try await client.setBatteryChargePolicy(.limit80); rig.access { $0.batteryPresence = .notObserved }
        _ = try await wait(client) { $0.phase == .off && $0.support == .noInternalBattery }
        XCTAssertNil(rig.access { $0.record }); XCTAssertEqual(rig.access { $0.bytes }, [0, 0, 0, 0])
    }
    func testProtocol7SelectorStillWorksAndDisconnectRestoresItsPrivateOwner() async throws {
        let rig = Rig(), endpoint = Endpoint(rig); defer { endpoint.stop() }
        let connection = NSXPCConnection(listenerEndpoint: endpoint.listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: LegacyBatteryHelper.self); connection.resume(); defer { connection.invalidate() }
        let _: Void = try await legacyCall(connection) { proxy, done in
            proxy.setBatteryChargePolicy("limit80") { error in
                if let error { done(.failure(BatteryGateError(error))) } else { done(.success(())) }
            }
        }
        let data: Data = try await legacyCall(connection) { proxy, done in proxy.batteryChargeState { done(.success($0)) } }
        let owned = try PolicyCoding.decoder().decode(BatteryChargeState.self, from: data)
        XCTAssertTrue(owned.ownedByCaller); XCTAssertNotNil(owned.sessionID); XCTAssertEqual(owned.phase, .holding)
        let observer = endpoint.client(); defer { observer.reset() }
        let foreign = try await observer.batteryChargeState(); XCTAssertFalse(foreign.ownedByCaller)
        connection.invalidate(); _ = try await wait(observer) { $0.phase == .off }
        XCTAssertNil(rig.access { $0.record }); XCTAssertEqual(rig.access { $0.bytes }, [0, 0, 0, 0])
    }
    func testFullCompletionResumesPreviouslyOwned80LimitOnSameConnection() async throws {
        let rig = Rig(), endpoint = Endpoint(rig); defer { endpoint.stop() }; let client = endpoint.client(); defer { client.reset() }
        try await client.setBatteryChargePolicy(.limit80); try await client.setBatteryChargePolicy(.chargeToFull)
        let full = try await client.batteryChargeState(); XCTAssertEqual(full.policy, .chargeToFull); XCTAssertEqual(full.gate, .allowed)
        rig.access { $0.percent = 100 }
        let resumed = try await wait(client) { $0.policy == .limit80 && $0.phase == .holding }
        XCTAssertEqual(resumed.lastFullChargeEndReason, .fullyCharged); XCTAssertEqual(resumed.sessionID, full.sessionID)
        XCTAssertTrue(resumed.ownedByCaller); XCTAssertEqual(rig.access { $0.bytes }, [1, 0, 0, 0])
    }
    func testStandaloneFullCompletionEndsInsteadOfCreatingAn80Limit() async throws {
        let rig = Rig(), endpoint = Endpoint(rig); defer { endpoint.stop() }; let client = endpoint.client(); defer { client.reset() }
        try await client.setBatteryChargePolicy(.chargeToFull); rig.access { $0.percent = 100 }
        let ended = try await wait(client) { $0.policy == .off && $0.phase == .off }
        XCTAssertEqual(ended.lastFullChargeEndReason, .fullyCharged); XCTAssertFalse(ended.ownedByCaller); XCTAssertNil(ended.sessionID)
        XCTAssertEqual(rig.access { $0.writes }, 0); XCTAssertNil(rig.access { $0.record })
    }
    func testUnplugEndsFullOverrideAndReplugUsesTheOriginal80Policy() async throws {
        let rig = Rig(), endpoint = Endpoint(rig); defer { endpoint.stop() }; let client = endpoint.client(); defer { client.reset() }
        try await client.setBatteryChargePolicy(.limit80); try await client.setBatteryChargePolicy(.chargeToFull)
        rig.access { $0.plugged = false }
        let resumed = try await wait(client) { $0.policy == .limit80 && $0.phase == .watching }
        XCTAssertEqual(resumed.lastFullChargeEndReason, .unplugged); XCTAssertNil(rig.access { $0.record })
        rig.access { $0.plugged = true }; _ = try await wait(client) { $0.phase == .holding }
    }
    func testUnknownPowerEndsFullWithoutPretendingItReached100() async throws {
        let rig = Rig(), endpoint = Endpoint(rig); defer { endpoint.stop() }; let client = endpoint.client(); defer { client.reset() }
        try await client.setBatteryChargePolicy(.limit80); try await client.setBatteryChargePolicy(.chargeToFull)
        rig.access { $0.plugged = nil }
        let blocked = try await wait(client) { $0.policy == .limit80 && $0.phase == .blocked }
        XCTAssertEqual(blocked.lastFullChargeEndReason, .observationUnavailable); XCTAssertEqual(blocked.gate, .allowed)
        rig.access { $0.plugged = true }; _ = try await wait(client) { $0.phase == .holding }
    }
    func testRepeatedFullRequestRetainsItsOriginalReturnPolicy() async throws {
        let rig = Rig(), endpoint = Endpoint(rig); defer { endpoint.stop() }; let client = endpoint.client(); defer { client.reset() }
        try await client.setBatteryChargePolicy(.limit80); try await client.setBatteryChargePolicy(.chargeToFull)
        try await client.setBatteryChargePolicy(.chargeToFull); rig.access { $0.percent = 100 }
        _ = try await wait(client) { $0.policy == .limit80 && $0.phase == .holding }
    }
    func testChargeControlDisappearingDuringFullEndsWithoutReapplyingAfterItReturns() async throws {
        let rig = Rig(), endpoint = Endpoint(rig); defer { endpoint.stop() }
        let client = endpoint.client(); defer { client.reset() }
        try await client.setBatteryChargePolicy(.limit80)
        try await client.setBatteryChargePolicy(.chargeToFull)
        let writesBeforeLoss = rig.access { $0.writes }
        rig.access { $0.hasChargeKeys = false }
        let ended = try await wait(client) { $0.policy == .off && $0.lastFullChargeEndReason == .supportChanged }
        XCTAssertFalse(ended.ownedByCaller); XCTAssertNil(ended.sessionID)
        XCTAssertNil(rig.access { $0.record }); XCTAssertEqual(rig.access { $0.bytes }, [0, 0, 0, 0])
        rig.access { $0.hasChargeKeys = true }
        _ = try await wait(client) { $0.support == .smc }
        // Cross a timer tick after capability recovers, then query again. Restored
        // capability alone must not recreate the old owner's charging policy.
        try await Task.sleep(nanoseconds: 100_000_000)
        let recovered = try await client.batteryChargeState()
        XCTAssertEqual(recovered.policy, .off)
        XCTAssertEqual(rig.access { $0.writes }, writesBeforeLoss)
    }
}
