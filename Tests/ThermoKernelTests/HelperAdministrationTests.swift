import Combine
import Foundation
import SystemServicesAPI
import ThermoKit
import XCTest
@testable import ThermoKernel

@MainActor final class HelperAdministrationTests:XCTestCase {
    private final class Latch:@unchecked Sendable {
        private let lock=NSLock();private var ready=false
        private var waiter:CheckedContinuation<Void,Never>?
        func wait() async{await withCheckedContinuation{done in lock.lock();if ready{lock.unlock();done.resume()}else{waiter=done;lock.unlock()}}}
        func release(){lock.lock();ready=true;let done=waiter;waiter=nil;lock.unlock();done?.resume()}
    }
    private final class Transport:KernelHelperTransport,@unchecked Sendable {
        let entered=XCTestExpectation(description:"lid observation held"),latch=Latch()
        let block:Bool
        private let lock=NSLock();private var versions=0,writes=0
        var versionCount:Int{lock.lock();defer{lock.unlock()};return versions}
        var writeCount:Int{lock.lock();defer{lock.unlock()};return writes}
        init(block:Bool = false){self.block=block}
        private func versionRead(){lock.lock();versions+=1;lock.unlock()}
        private func wrote(){lock.lock();writes+=1;lock.unlock()}
        func version() async throws->String{versionRead();return HelperConstants.version}
        func fanControlState() async throws->FanControlState{.init(policies:[:])}
        func lidAwakeState() async throws->LidAwakeState{if block{entered.fulfill();await latch.wait()};return .init(limit:80)}
        func setPolicy(_ policy:FanPolicy,fan:Int) async throws{wrote()}
        func setLidAwake(_ on:Bool,heatGuard:Bool) async throws{wrote()}
        func withRemovalPreparation(_ remove:()throws->Void)throws{try remove()}
        func reset(){}
    }
    private func owner(_ transport:Transport,automatic:Bool = true,begin:@escaping ()->UUID = {UUID()},end:@escaping (UUID)->Void = {_ in})->CoreHelperAdministration {
        .init(transport:transport,automaticInteractionAllowed:automatic,usesSMAppService:false,beginMaintenance:begin,endMaintenance:end,recordFan:{_,_,_,_ in})
    }
    func testPassiveObservationAndUnavailableClientDoNotContactHelper() async {
        let transport=Transport(),service=owner(transport)
        let subscription=service.readings.sink{_ in}
        let client=service.bind(available:{false});client.refreshObservation();client.request(.auto,fans:[0]);await client.finishRetiring()
        XCTAssertEqual(service.latest.phase,.unknown);XCTAssertEqual(transport.versionCount,0);XCTAssertEqual(transport.writeCount,0)
        XCTAssertTrue(service.latest.pendingPolicies.isEmpty);withExtendedLifetime(subscription){}
    }
    func testClientRetirementJoinsNestedLidReadAndDiscardsLateObservation() async {
        let transport=Transport(block:true),service=owner(transport)
        defer{transport.latch.release()}
        let client=service.bind(available:{true});client.refreshObservation()
        await fulfillment(of:[transport.entered],timeout:3)
        client.beginRetiring();var finished=false
        let drain=Task{await client.finishRetiring();finished=true}
        await Task.yield();XCTAssertFalse(finished)
        client.request(.fixed(rpm:2500),fans:[0]);XCTAssertTrue(service.latest.pendingPolicies.isEmpty)
        transport.latch.release();await drain.value
        XCTAssertEqual(service.latest.phase,.unknown);XCTAssertEqual(transport.writeCount,0)
        XCTAssertNil(service.latest.lidAwake)
    }
    func testRetiredClientCannotRequestPolicyAfterAnotherClientObservesRunningHelper() async {
        let transport=Transport(),service=owner(transport),old=service.bind(available:{true})
        await old.finishRetiring();let fresh=service.bind(available:{true});fresh.refreshObservation()
        for _ in 0..<200 where service.latest.phase != .running{try? await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(service.latest.phase,.running)
        old.request(.fixed(rpm:2500),fans:[0]);old.refreshObservation()
        XCTAssertFalse(service.latest.applyingPolicies);XCTAssertTrue(service.latest.pendingPolicies.isEmpty)
        await fresh.finishRetiring();XCTAssertEqual(transport.writeCount,0);XCTAssertEqual(transport.versionCount,1)
    }
    func testMaintenanceGuardCoversActualOwnedOperationUntilTerminalCallback() async {
        let transport=Transport();var tokens=Set<UUID>()
        let service=owner(transport,automatic:false,begin:{let token=UUID();tokens.insert(token);return token},end:{tokens.remove($0)})
        let began=expectation(description:"fake installer held"),finished=expectation(description:"fake installer returned"),release=DispatchSemaphore(value:0)
        defer{release.signal();service.stopSetup()}
        service.performInstallation(operation:{began.fulfill();release.wait()},finished:{finished.fulfill()})
        await fulfillment(of:[began],timeout:3)
        XCTAssertEqual(tokens.count,1);XCTAssertFalse(service.latest.canRetirePerformance)
        release.signal();await fulfillment(of:[finished],timeout:3)
        XCTAssertTrue(tokens.isEmpty);XCTAssertFalse(service.latest.installing);XCTAssertEqual(transport.writeCount,0)
    }
}
