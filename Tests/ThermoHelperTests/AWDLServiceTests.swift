import Foundation
import XCTest
@testable import ThermoKit
@testable import ThermoHelper

final class AWDLServiceTests: XCTestCase {
    final class Rig: @unchecked Sendable {
        private let lock=NSLock()
        private var up=true,record: AWDLRestoreRecord?,time=100.0,writes=0
        private var restored: (@Sendable () -> Void)?
        func onRestore(_ callback: @escaping @Sendable () -> Void) { lock.lock();restored=callback;lock.unlock() }
        private func didRestore() { lock.lock();let callback=restored;lock.unlock();callback?() }
        func access<T>(_ body: (inout Bool,inout AWDLRestoreRecord?,inout Double,inout Int) -> T) -> T {
            lock.lock();defer { lock.unlock() };return body(&up,&record,&time,&writes)
        }
        func controller() -> AWDLSessionController {
            .init(io:.init(read:{ self.access { up,_,_,_ in .init(index:15,up:up) } },write:{ _,value in
                self.access { up,record,_,writes in XCTAssertNotNil(record);up=value;writes+=1 }
                if value { self.didRestore() }
            }),store:.init(load:{ self.access { _,record,_,_ in record } },save:{ value in
                self.access { _,record,_,_ in XCTAssertNil(record);record=value }
            },clear:{ value in self.access { _,record,_,_ in XCTAssertEqual(record,value);record=nil } }),
                boot:{ "22222222-2222-2222-2222-222222222222" },clock:{ self.access { _,_,time,_ in time } })
        }
    }
    final class Endpoint: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        let listener=NSXPCListener.anonymous()
        let network: AWDLHelperCoordinator
        let fans: FanHost
        let lock=NSLock()
        var connections: [NSXPCConnection]=[]
        init(rig: Rig,fanGate: DispatchSemaphore? = nil) {
            network=AWDLHelperCoordinator(make:{ rig.controller() },tickInterval:0.03)
            fans=FanHost(make:{ _,_ in
                if let fanGate { _=fanGate.wait(timeout:.now()+5) }
                throw AWDLError("fixture SMC unavailable")
            },fallbackSleep:nil,saveAutomatic:{})
            super.init();listener.delegate=self;listener.resume()
        }
        func listener(_ listener: NSXPCListener,shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
            let service=Service(fans:fans,network:network)
            c.exportedInterface=NSXPCInterface(with:ThermoHelperProtocol.self);c.exportedObject=service
            c.invalidationHandler={ service.disconnected() };c.interruptionHandler={ service.disconnected() }
            lock.lock();connections.append(c);lock.unlock();c.resume();return true
        }
        func client() -> HelperClient { HelperClient(makeConnection:{ NSXPCConnection(listenerEndpoint:self.listener.endpoint) }) }
        func stop() {
            lock.lock();let values=connections;connections=[];lock.unlock()
            for c in values { c.invalidate() };listener.invalidate()
        }
    }
    func wait(_ client: HelperClient,_ predicate: (AWDLSessionState) -> Bool) async throws -> AWDLSessionState {
        for _ in 0..<50 {
            let state=try await client.awdlState();if predicate(state) { return state }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        XCTFail("AWDL state did not reach expected condition");return try await client.awdlState()
    }
    func testRealServiceXPCWorksWithoutSMCAndDoesNotInventAutomaticFans() async throws {
        let rig=Rig(),endpoint=Endpoint(rig:rig);defer { endpoint.stop() }
        let client=endpoint.client();defer { client.reset() }
        let version=try await client.version();XCTAssertTrue(version.hasPrefix("7/"))
        let id=UUID().uuidString;try await client.beginAWDL(seconds:60,sessionID:id)
        let active=try await client.awdlState();XCTAssertEqual(active.sessionID,id);XCTAssertTrue(active.ownedByCaller)
        XCTAssertFalse(active.interface!.up)
        let fan=try await client.fanControlState();XCTAssertNotNil(fan.failure)
        do { _=try await client.policies();XCTFail("unavailable fans are not confirmed automatic") } catch {}
        try await client.endAWDL();let ended=try await client.awdlState();XCTAssertEqual(ended.phase,.idle)
        XCTAssertTrue(rig.access { up,record,_,_ in up && record == nil })
    }
    func testBlockedFanStartupDoesNotBlockNetworkRecoveryOrState() async throws {
        let gate=DispatchSemaphore(value:0),rig=Rig()
        rig.access { up,record,_,_ in up=false;record = .init(index:15,wasUp:true,bootSession:"22222222-2222-2222-2222-222222222222") }
        let endpoint=Endpoint(rig:rig,fanGate:gate);defer { gate.signal();endpoint.stop() }
        let client=endpoint.client();defer { client.reset() }
        let state=try await client.awdlState();XCTAssertEqual(state.phase,.idle);XCTAssertTrue(state.interface!.up)
        XCTAssertTrue(rig.access { up,record,_,_ in up && record == nil })
    }
    func testOwnershipAndClientDisconnectRecoverThroughActualXPC() async throws {
        let rig=Rig(),endpoint=Endpoint(rig:rig);defer { endpoint.stop() }
        let first=endpoint.client(),other=endpoint.client();defer { first.reset();other.reset() }
        try await first.beginAWDL(seconds:60)
        let observed=try await other.awdlState();XCTAssertFalse(observed.ownedByCaller)
        do { try await other.endAWDL();XCTFail("another connection cannot end an active lease") } catch {}
        XCTAssertFalse(rig.access { up,_,_,_ in up })
        first.reset();_=try await wait(other) { $0.phase == .idle }
        XCTAssertTrue(rig.access { up,record,_,_ in up && record == nil })
    }
    func testTimerExpiresSessionWithoutAClientPollingLoop() async throws {
        let rig=Rig(),endpoint=Endpoint(rig:rig);defer { endpoint.stop() }
        let client=endpoint.client();defer { client.reset() };try await client.beginAWDL(seconds:60)
        let restored=expectation(description:"timer restored without a state request")
        rig.onRestore { restored.fulfill() }
        rig.access { _,_,time,_ in time+=61 }
        await fulfillment(of:[restored],timeout:3)
        let state=try await client.awdlState();XCTAssertEqual(state.phase,.idle)
        XCTAssertTrue(rig.access { up,record,_,_ in up && record == nil })
    }
    func testRemovalRestoresNetworkEvenWhenFansCannotBeVerified() async throws {
        let rig=Rig(),endpoint=Endpoint(rig:rig);defer { endpoint.stop() }
        let client=endpoint.client();defer { client.reset() };try await client.beginAWDL(seconds:60)
        let token=UUID().uuidString
        do { try await client.prepareRemoval(true,token:token);XCTFail("unknown fan recovery must prevent removal") } catch {}
        XCTAssertTrue(rig.access { up,record,_,_ in up && record == nil })
        do { try await client.beginAWDL(seconds:60);XCTFail("failed preparation remains fenced") } catch {}
        try await client.prepareRemoval(false,token:token)
        try await client.beginAWDL(seconds:60);try await client.endAWDL()
    }
    func testClosedConnectionCannotActivateARequestWaitingBehindStartup() async throws {
        let rig=Rig(),gate=DispatchSemaphore(value:0),owner=AWDLConnectionOwner()
        let manager=AWDLHelperCoordinator(make:{ _=gate.wait(timeout:.now()+5);return rig.controller() },tickInterval:0.03)
        let done=expectation(description:"late request rejected")
        manager.begin(owner:owner,seconds:60,sessionID:UUID().uuidString) { error in XCTAssertNotNil(error);done.fulfill() }
        owner.close();manager.disconnected(owner:owner);gate.signal()
        await fulfillment(of:[done],timeout:3)
        XCTAssertEqual(rig.access { _,_,_,writes in writes },0)
    }
    func testRemovalRestoresNetworkWhileFanPreparationIsStillBlocked() async throws {
        let rig=Rig(),gate=DispatchSemaphore(value:0),endpoint=Endpoint(rig:rig,fanGate:gate)
        defer { gate.signal();endpoint.stop() }
        let client=endpoint.client();defer { client.reset() };try await client.beginAWDL(seconds:60)
        let preparation=Task { try await client.prepareRemoval(true,token:UUID().uuidString) }
        _=try await wait(client) { $0.phase == .idle }
        XCTAssertTrue(rig.access { up,record,_,_ in up && record == nil })
        gate.signal()
        do { try await preparation.value;XCTFail("unverified fan recovery must still reject removal") } catch {}
    }
}
