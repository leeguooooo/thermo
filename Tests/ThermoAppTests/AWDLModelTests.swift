import XCTest
import ThermoKit
@testable import ThermoApp

final class AWDLModelTests: XCTestCase {
    actor FlushGate {
        var continuation: CheckedContinuation<Void,Never>?
        let entered: XCTestExpectation
        init(_ entered: XCTestExpectation) { self.entered=entered }
        func wait() async { await withCheckedContinuation { continuation=$0;entered.fulfill() } }
        func release() { continuation?.resume();continuation=nil }
    }
    actor Rig {
        var value: AWDLSessionState
        var failEnd=false,failRead=false,failBeforeSend=false,failAfterSend=false
        var starts=0
        init() { var s=AWDLSessionState();s.phase = .idle;s.interfaceQueryComplete=true;s.interface = .init(index:15,up:true);value=s }
        nonisolated var backend: AWDLBackend {
            .init(read:{ try await self.read() },begin:{ try await self.begin($0,$1) },end:{ try await self.end() },reset:{})
        }
        func read() throws -> AWDLSessionState { if failRead { throw AWDLError("fixture read unavailable") };return value }
        func begin(_ seconds: Int,_ id: String) throws {
            if failBeforeSend { failRead=true;throw AWDLClientError.notStarted("fixture old helper") }
            starts+=1;value.phase = .active;value.sessionID=id;value.ownedByCaller=true;value.remainingSeconds=seconds;value.interface?.up=false
            if failAfterSend { value.phase = .recovering;value.ownedByCaller=false;value.remainingSeconds=nil;throw AWDLError("fixture begin uncertain") }
        }
        func end() throws {
            if failEnd || (value.phase == .active && !value.ownedByCaller) {
                value.phase = .recovering;value.ownedByCaller=false;value.remainingSeconds=nil;throw AWDLError("fixture recovery pending")
            }
            recover()
        }
        func recover() { failRead=false;failEnd=false;value.phase = .idle;value.sessionID=nil;value.ownedByCaller=false;value.remainingSeconds=nil;value.interface?.up=true }
        func setFaults(end: Bool=false,before: Bool=false,after: Bool=false) { failEnd=end;failBeforeSend=before;failAfterSend=after }
        func loseOwnership(sameSession: Bool) { value.ownedByCaller=false;if !sameSession { value.sessionID=UUID().uuidString } }
    }
    @MainActor func settle(_ model: AWDLModel) async {
        for _ in 0..<200 { if !model.busy { return };try? await Task.sleep(nanoseconds:10_000_000) }
        XCTFail("model remained busy")
    }
    @MainActor func testOpenQueriesOnlyAndStartRequiresKnownIdleState() async {
        let rig=Rig(),model=AWDLModel(backend:rig.backend,exit:{})
        model.start(seconds:60);XCTAssertFalse(model.busy)
        model.open();await settle(model);XCTAssertTrue(model.canStart)
        let starts=await rig.starts;XCTAssertEqual(starts,0)
        model.start(seconds:60);await settle(model)
        XCTAssertTrue(model.needsQuitRecovery);XCTAssertFalse(model.canStart);XCTAssertTrue(model.canStop)
        model.stop();await settle(model);XCTAssertFalse(model.needsQuitRecovery);model.close()
    }
    @MainActor func testQuitWaitsForConfirmedRecoveryAndOnlyExitsOnce() async {
        let rig=Rig();var exits=0
        let model=AWDLModel(backend:rig.backend,exit:{ exits+=1 })
        model.open();await settle(model);model.start(seconds:60);await settle(model)
        await rig.setFaults(end:true)
        XCTAssertTrue(model.requestQuit());await settle(model)
        XCTAssertEqual(exits,0);XCTAssertTrue(model.quitRequested);XCTAssertTrue(model.needsQuitRecovery)
        await rig.recover();model.refresh();await settle(model)
        XCTAssertEqual(exits,1);XCTAssertFalse(model.quitRequested);XCTAssertFalse(model.needsQuitRecovery)
        model.refresh();await settle(model);XCTAssertEqual(exits,1);model.close()
    }
    @MainActor func testUncertainBeginRemainsProtectedUntilReadbackConfirmsEnd() async {
        let rig=Rig(),model=AWDLModel(backend:rig.backend,exit:{})
        model.open();await settle(model);await rig.setFaults(after:true)
        model.start(seconds:60);await settle(model)
        XCTAssertTrue(model.needsQuitRecovery);XCTAssertEqual(model.state?.phase,.recovering)
        await rig.recover();model.refresh();await settle(model);XCTAssertFalse(model.needsQuitRecovery);model.close()
    }
    @MainActor func testKnownPreSendFailureDoesNotTrapNormalExit() async {
        let rig=Rig(),model=AWDLModel(backend:rig.backend,exit:{})
        model.open();await settle(model);await rig.setFaults(before:true)
        model.start(seconds:60);await settle(model)
        XCTAssertNil(model.state);XCTAssertNotNil(model.issue);XCTAssertFalse(model.needsQuitRecovery);XCTAssertFalse(model.requestQuit());model.close()
    }
    @MainActor func testReconnectToSameSessionDoesNotInventRestoration() async {
        let rig=Rig(),model=AWDLModel(backend:rig.backend,exit:{})
        model.open();await settle(model);model.start(seconds:60);await settle(model)
        await rig.loseOwnership(sameSession:true);model.refresh();await settle(model)
        XCTAssertTrue(model.needsQuitRecovery)
        await rig.recover();model.refresh();await settle(model);XCTAssertFalse(model.needsQuitRecovery);model.close()
    }
    @MainActor func testDifferentActiveSessionIsNotStoppedAsOurs() async {
        let rig=Rig(),model=AWDLModel(backend:rig.backend,exit:{})
        model.open();await settle(model);model.start(seconds:60);await settle(model)
        await rig.loseOwnership(sameSession:false);model.refresh();await settle(model)
        XCTAssertFalse(model.needsQuitRecovery);XCTAssertFalse(model.canStop);XCTAssertFalse(model.requestQuit());model.close()
    }
    @MainActor func testExitPreparationCannotBeBypassedByASecondNormalQuit() async {
        let rig=Rig(),entered=expectation(description:"history fence entered"),gate=FlushGate(entered)
        var backend=rig.backend;backend.flush={ await gate.wait() };var exits=0
        let model=AWDLModel(backend:backend,exit:{ exits+=1 })
        model.open();await settle(model);model.start(seconds:60);await settle(model)
        XCTAssertTrue(model.requestQuit());await fulfillment(of:[entered],timeout:3)
        XCTAssertFalse(model.needsQuitRecovery);XCTAssertTrue(model.busy);XCTAssertEqual(exits,0)
        XCTAssertTrue(model.requestQuit());XCTAssertFalse(model.canStart)
        await gate.release();await settle(model);XCTAssertEqual(exits,1);model.close()
    }
}
