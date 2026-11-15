import ModuleKit
import XCTest
@testable import AgentDoctor
@testable import ThermoApp

@MainActor final class AgentModuleLifecycleTests:XCTestCase {
    private nonisolated static func report()->DoctorReport {
        .init(generated:Date(),inventory:Inventory(),findings:[],items:[],processes:[],sessions:0)
    }
    private nonisolated static func usage()->ToolUsageReport {
        .init(generated:Date(),since:Date(),until:Date(),complete:true,coverage:.init(),tools:[],sessionTokens:[],note:"Fixture")
    }
    private func item()->AgentItem {.init(id:"fixture",area:.mcp,agent:"fixture",name:"Fixture",detail:"",source:nil,enabled:true,severity:.warning)}
    private func action()->Action {.init(id:"fixture",kind:.fix,title:"Fixture",summary:"",steps:[],destructive:false)}
    private func defaults()->UserDefaults {
        let name="thermo-agent-module-"+UUID().uuidString
        let settings=UserDefaults(suiteName:name)!
        addTeardownBlock{settings.removePersistentDomain(forName:name)}
        return settings
    }
    func testRegistryOwnsAllDiagnosticAreasAndCommandSix() {
        XCTAssertTrue(BuiltinModules.problems.isEmpty,BuiltinModules.problems.joined(separator:"\n"))
        XCTAssertFalse(HostPageSpecification.pages.contains{$0.argument=="agents"})
        XCTAssertEqual(BuiltinModules.page(.agents(.home))?.entry.navigationKey,"6")
        XCTAssertEqual(Set(AgentDiagnosticsModule.manifest.entries.compactMap{$0.scene.flatMap(AgentDiagnosticsModule.target)}),Set([MainPage.agents(.home)]+Area.allCases.map{.agents(.area($0))}))
        for area in Area.allCases {
            let page=MainPage.agents(.area(area))
            XCTAssertEqual(BuiltinModules.page(page)?.target,page)
            XCTAssertEqual(MainPage(argument:"agents:"+area.rawValue),page)
            XCTAssertEqual(BuiltinModules.page(.module(AgentDiagnosticsModule.manifest.id,area.rawValue))?.target,page)
        }
    }
    func testColdOffRefusesScanRepairsMCPUsageAndImports() async {
        let scanner=AgentScanner(enabled:{false},performAction:{_,_ in XCTFail("off repair");return .init(ok:false,log:[],backups:[])},diagnose:{XCTFail("off scan");return Self.report()},inspectMCP:{_ in XCTFail("off MCP");return .init(generated:Date(),name:"fixture",agent:"fixture",state:.ready)})
        XCTAssertTrue(scanner.work === scanner.toolUsage.work)
        XCTAssertTrue(scanner.work === scanner.taskComparison.work)
        XCTAssertTrue(scanner.work === scanner.mcpDefinitions.work)
        scanner.scan();scanner.selectProject(URL(fileURLWithPath:"/must-not-read"));scanner.selectEncoding(.heuristic)
        scanner.perform(action(),on:item())
        scanner.performAll([(item(),action())],executor:{_ in XCTFail("off batch");return .init(ok:false,log:[],backups:[])},rescan:{Self.report()})
        XCTAssertFalse(scanner.mcpBatch.start(items:[item()],encoding:.heuristic))
        let usage=ToolUsageModel(work:scanner.work,analyzer:{_,_,_,_,_ in XCTFail("off usage");return Self.usage()})
        usage.analyze();scanner.taskComparison.load(URL(fileURLWithPath:"/must-not-read"))
        let inspection=MCPInspectionModel();inspection.inspect(item(),scope:scanner.work)
        await scanner.work.finish()
        XCTAssertFalse(scanner.busy || usage.running || inspection.running)
        XCTAssertNil(scanner.report);XCTAssertEqual(scanner.work.count,0)
    }
    func testStopDrainsUncooperativeDiagnosisAndRejectsLateReport() async {
        let entered=expectation(description:"diagnose"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        let scanner=AgentScanner(diagnose:{entered.fulfill();_ = release.wait(timeout:.now()+5);return Self.report()})
        scanner.scan();await fulfillment(of:[entered],timeout:2)
        scanner.stopFeature()
        var finished=false;let finish=Task {await scanner.finishFeatureStop();finished=true}
        await Task.yield();XCTAssertFalse(finished)
        release.signal();await finish.value
        XCTAssertNil(scanner.report);XCTAssertFalse(scanner.scanning);XCTAssertEqual(scanner.work.count,0)
    }
    func testStopDrainsMCPInspectionWithoutKeepingItsLateDefinitions() async {
        let entered=expectation(description:"MCP"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        let scanner=AgentScanner(inspectMCP:{request in
            entered.fulfill();_ = release.wait(timeout:.now()+5)
            var result=MCPInspection(generated:Date(),name:request.id,agent:"fixture",state:.ready)
            result.complete=true;result.definitions=TextFootprint("[]");result.instructions=TextFootprint("");return result
        })
        XCTAssertTrue(scanner.mcpBatch.start(items:[item()],encoding:.heuristic))
        await fulfillment(of:[entered],timeout:2);scanner.stopFeature()
        var finished=false;let finish=Task {await scanner.finishFeatureStop();finished=true}
        await Task.yield();XCTAssertFalse(finished)
        release.signal();await finish.value
        XCTAssertFalse(scanner.mcpBatch.running);XCTAssertTrue(scanner.mcpBatch.rows.isEmpty)
        XCTAssertTrue(scanner.mcpDefinitions.entries.isEmpty);XCTAssertTrue(scanner.mcpDefinitions.pending.isEmpty)
    }
    func testStopCancelsUsageButStillWaitsForUsageAndComparisonReaders() async {
        let usageEntered=expectation(description:"usage"),comparisonEntered=expectation(description:"comparison"),cancelled=expectation(description:"usage cancelled")
        let usageRelease=DispatchSemaphore(value:0),comparisonRelease=DispatchSemaphore(value:0)
        defer{usageRelease.signal();comparisonRelease.signal()}
        let scanner=AgentScanner()
        let usage=ToolUsageModel(work:scanner.work,analyzer:{_,_,_,_,cancellation in
            usageEntered.fulfill()
            let end=Date().addingTimeInterval(3)
            while !cancellation.isCancelled && Date()<end {Thread.sleep(forTimeInterval:0.005)}
            XCTAssertTrue(cancellation.isCancelled);cancelled.fulfill()
            _ = usageRelease.wait(timeout:.now()+5);return Self.usage()
        })
        let comparison=TaskComparisonModel(work:scanner.work,reader:{_ in
            comparisonEntered.fulfill();_ = comparisonRelease.wait(timeout:.now()+5)
            throw NSError(domain:"fixture",code:1)
        })
        usage.analyze();comparison.load(URL(fileURLWithPath:"/fixture"))
        await fulfillment(of:[usageEntered,comparisonEntered],timeout:2)
        scanner.stopFeature();await fulfillment(of:[cancelled],timeout:2)
        var finished=false;let finish=Task {await scanner.finishFeatureStop();finished=true}
        await Task.yield();XCTAssertFalse(finished)
        usageRelease.signal();await Task.yield();XCTAssertFalse(finished)
        comparisonRelease.signal();await finish.value
        XCTAssertNil(usage.report);XCTAssertFalse(usage.running)
        XCTAssertNil(comparison.report);XCTAssertFalse(comparison.loading)
    }
    func testConfirmedSingleAndBatchRepairsRefuseDisableAndQuit() async throws {
        for batch in [false,true] {
            let entered=expectation(description:"fake repair"),release=DispatchSemaphore(value:0)
            defer{release.signal()}
            let execute:@Sendable ()->ActionResult = {entered.fulfill();_ = release.wait(timeout:.now()+5);return .init(ok:true,log:["fixture"],backups:[])}
            let scanner=AgentScanner(performAction:{_,_ in execute()},diagnose:{Self.report()})
            let models=AppModels(defaults:defaults(),makeAgents:{gate in scanner.work.enabled=gate;return scanner})
            _=models.agents
            if batch {scanner.performAll([(item(),action())],executor:{_ in execute()},rescan:{Self.report()})}
            else {scanner.perform(action(),on:item())}
            await fulfillment(of:[entered],timeout:2)
            XCTAssertEqual(models.agentsExitBlocker(),.agents(.home))
            XCTAssertThrowsError(try AgentDiagnosticsModule.prepareStop(models:models));XCTAssertFalse(scanner.work.stopping)
            scanner.stopScan();release.signal();await scanner.work.finish()
            XCTAssertEqual(scanner.history.count,1)
            if let finish=try AgentDiagnosticsModule.prepareStop(models:models){await finish()}
            XCTAssertFalse(models.agentsLoaded);XCTAssertTrue(scanner.history.isEmpty)
        }
    }
    func testOffNavigationAndOverlaysStayColdAndReenableCreatesFreshScanner() async throws {
        let defaults=defaults();var creations=0
        let models=AppModels(defaults:defaults,makeAgents:{gate in creations += 1;return AgentScanner(enabled:gate,diagnose:{Self.report()})})
        let center=ModuleCenter(defaults:defaults,prepareBuiltinStop:{_ in try AgentDiagnosticsModule.prepareStop(models:models)})
        center.setEnabled(AgentDiagnosticsModule.manifest.id,false)
        _=AgentDiagnosticsModule.overlay(models:models)
        XCTAssertNil(center.navigationKey(.agents(.home)));XCTAssertFalse(center.shows(.agents(.area(.mcp))))
        XCTAssertFalse(models.agentsLoaded);XCTAssertEqual(creations,0)
        defaults.set(true,forKey:ModulePreferences.key(AgentDiagnosticsModule.manifest.id))
        XCTAssertEqual(center.navigationKey(.agents(.home)),"6")
        let old=models.agents
        if let finish=try AgentDiagnosticsModule.prepareStop(models:models){await finish()}
        old.scan();XCTAssertEqual(old.work.count,0)
        let fresh=models.agents;XCTAssertFalse(fresh === old);XCTAssertEqual(creations,2)
        if let finish=try AgentDiagnosticsModule.prepareStop(models:models){await finish()}
    }
}
