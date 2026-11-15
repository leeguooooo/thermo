import AppKit
import ModuleKit
import NativeFeatureAPI
import XCTest
@testable import AgentDoctor
@testable import AgentDiagnosticsFeature
@testable import ThermoShell
@testable import ThermoComposition

@MainActor final class AgentExitGuardIntegrationTests:ThermoCompositionTestCase {
    private nonisolated static func report()->DoctorReport {.init(generated:Date(),inventory:Inventory(),findings:[],items:[],processes:[],sessions:0)}
    private func item()->AgentItem {.init(id:"fixture",area:.mcp,agent:"fixture",name:"Fixture",detail:"",source:nil,enabled:true,severity:.warning)}
    private func action()->Action {.init(id:"fixture",kind:.fix,title:"Fixture",summary:"",steps:[],destructive:false)}
    func testConfirmedSingleAndBatchRepairsRefuseDisableAndQuit() async throws {
        for batch in [false,true] {
            let entered=expectation(description:"fake repair"),release=DispatchSemaphore(value:0)
            defer{release.signal()}
            let execute:@Sendable ()->ActionResult = {entered.fulfill();_ = release.wait(timeout:.now()+5);return .init(ok:true,log:["fixture"],backups:[])}
            let scanner=AgentScanner(performAction:{_,_ in execute()},diagnose:{Self.report()})
            let definition=NativeFeatureDefinition(manifest:BuiltinModuleManifests.agents,makeSession:{availability in
                AgentDiagnosticsSession(availability:availability,makeScanner:{gate in scanner.work.enabled=gate;return scanner})
            })
            let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true})
            _=store.page(.init(BuiltinModuleManifests.agents.id,"home"))
            if batch {scanner.performAll([(item(),action())],executor:{_ in execute()},rescan:{Self.report()})}
            else {scanner.perform(action(),on:item())}
            await fulfillment(of:[entered],timeout:2)
            var shown:[MainPage]=[]
            XCTAssertEqual(AppExitGuard.reply(nativeBlocker:{store.quitBlocker($0)},show:{shown.append($0)}),.terminateCancel)
            XCTAssertEqual(shown,[.native(.init(BuiltinModuleManifests.agents.id,"home"))])
            XCTAssertThrowsError(try store.prepareStop(BuiltinModuleManifests.agents.id));XCTAssertFalse(scanner.work.stopping)
            scanner.stopScan();release.signal();await scanner.work.finish()
            XCTAssertEqual(scanner.history.count,1)
            if let finish=try store.prepareStop(BuiltinModuleManifests.agents.id){await finish.finish()}
            XCTAssertFalse(store.status(BuiltinModuleManifests.agents.id).modelLoaded);XCTAssertTrue(scanner.history.isEmpty)
        }
    }
}
