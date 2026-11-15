import XCTest
import ModuleKit
@testable import CleanKit
@testable import BrowserFeature
import NativeFeatureAPI

@MainActor final class BrowserModuleLifecycleTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock=NSLock();private var value=0
        func hit(){lock.lock();value += 1;lock.unlock()}
        var count:Int{lock.lock();defer{lock.unlock()};return value}
    }
    private func defaults()->UserDefaults {
        let name="thermo-browser-module-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:name)!
        addTeardownBlock {defaults.removePersistentDomain(forName:name)}
        return defaults
    }
    private nonisolated static func inventory(_ app:String)->TabWorkspace.Inventory {
        .init(app:app,generated:Date(),pages:[])
    }
    private func actions(_ calls:Calls)->TabWorkspaceActions {
        .init(inventory:{app in calls.hit();return Self.inventory(app)},archives:{calls.hit();return []},assign:{_,_ in calls.hit()},archive:{_,app,name in calls.hit();return .init(name:name,app:app,entries:[])},remove:{_ in calls.hit()},restore:{_,_ in calls.hit();return .init(name:"Fixture",app:"Fixture",entries:[])})
    }
    func testColdOffCannotReadInventoryRecordsOrModifyTabs() async {
        let calls=Calls(),model=TabWorkspaceModel(enabled:{false},app:"Fixture",actions:actions(calls))
        let record=TabWorkspace.Archive(name:"Fixture",app:"Fixture",entries:[])
        model.refresh();model.group("x");model.archive([],name:"x");model.forget(record);model.restore(record)
        await model.work.finish()
        XCTAssertEqual(calls.count,0);XCTAssertFalse(model.busy)
        XCTAssertNil(model.inventory);XCTAssertTrue(model.saved.isEmpty)
    }
    func testStopDrainsPhysicalInventoryAndSkipsLateRecordRead() async {
        let calls=Calls(),entered=expectation(description:"inventory"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        var actions=actions(calls)
        actions.inventory={app in entered.fulfill();_ = release.wait(timeout:.now()+5);return Self.inventory(app)}
        let model=TabWorkspaceModel(app:"Fixture",actions:actions)
        model.refresh();await fulfillment(of:[entered],timeout:2)
        model.stopFeature()
        var drained=false;let finish=Task {await model.finishFeatureStop();drained=true}
        await Task.yield();XCTAssertFalse(drained)
        release.signal();await finish.value
        XCTAssertTrue(drained);XCTAssertEqual(calls.count,0)
        XCTAssertNil(model.inventory);XCTAssertFalse(model.didLoad)
    }
    func testAcceptedRestoreRefusesFeatureStopAndQuitUntilItReturns() async throws {
        let calls=Calls(),entered=expectation(description:"restore"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        var actions=actions(calls)
        actions.restore={_,_ in entered.fulfill();_ = release.wait(timeout:.now()+5);return .init(name:"Fixture",app:"Fixture",entries:[])}
        let model=TabWorkspaceModel(app:"Fixture",actions:actions)
        let session=BrowserSession(availability:FeatureAvailability(enabled:{true}),makeWorkspace:{gate,_ in model.work.enabled=gate;return model})
        _=session.workspace("Fixture")
        model.restore(.init(name:"Fixture",app:"Fixture",entries:[]))
        await fulfillment(of:[entered],timeout:2)
        XCTAssertEqual(session.quitBlocker()?.route,BrowserFeature.route("Fixture"))
        XCTAssertThrowsError(try session.prepareStop());XCTAssertFalse(model.work.stopping)
        release.signal();await model.work.finish()
        XCTAssertNil(session.quitBlocker())
        let drain=try session.prepareStop();await drain.finish()
        XCTAssertFalse(session.status.modelLoaded)
        XCTAssertGreaterThan(calls.count,0,"the post-action refresh also drains")
    }
    func testDisabledAutomationDoesNotReadConfigurationOrStartTimer() {
        var reads=0
        let automation=TabAutomation(enabled:{false},configuration:{reads += 1;return nil})
        automation.start();automation.tick();automation.stop();automation.tick()
        XCTAssertEqual(reads,0);XCTAssertFalse(automation.running)
    }
    func testRetiringQueuedReadDoesNotLeaveWorkspacePermanentlyBusy() async {
        let calls=Calls(),model=TabWorkspaceModel(app:"Fixture",actions:actions(calls))
        model.refresh();model.retireRead()
        await model.work.finish()
        XCTAssertFalse(model.busy)
        model.refresh();await model.work.finish()
        XCTAssertNotNil(model.inventory)
        XCTAssertEqual(calls.count,2)
        model.stopFeature();await model.finishFeatureStop()
    }
    func testStoppingDrainsCancelledDiagnosisAndItsPhysicalTabReader() async {
        let tabsEntered=expectation(description:"tabs"),diagnosisEntered=expectation(description:"diagnosis")
        let tabsRelease=DispatchSemaphore(value:0),diagnosisRelease=DispatchSemaphore(value:0)
        defer{tabsRelease.signal();diagnosisRelease.signal()}
        let actions=BrowserPageActions(tabs:{_ in tabsEntered.fulfill();_ = tabsRelease.wait(timeout:.now()+5);return []},
            close:{_,_ in XCTFail("no browser mutation requested");return []},
            reading:{_ in fatalError("no close reading requested")},wait:{},
            diagnose:{app,_,_,_,_,_ in
                diagnosisEntered.fulfill()
                await Task.detached {_ = diagnosisRelease.wait(timeout:.now()+5)}.value
                return .init(app:app,mode:.tabs,tabs:[],duplicates:[])
            })
        let model=ChromePagesModel(app:"Fixture",appMemoryKB:nil,gpuKB:nil,actions:actions)
        model.start();await fulfillment(of:[tabsEntered,diagnosisEntered],timeout:2)
        model.stop();XCTAssertFalse(model.running)
        model.stopFeature()
        var drained=false;let finish=Task {await model.finishFeatureStop();drained=true}
        await Task.yield();XCTAssertFalse(drained)
        diagnosisRelease.signal();await Task.yield();XCTAssertFalse(drained)
        tabsRelease.signal();await finish.value
        XCTAssertTrue(drained);XCTAssertNil(model.diagnosis);XCTAssertEqual(model.work.count,0)
    }

    func testColdOffBrowserDoesNotReadDiagnosticsOrAcceptFixtureResults() async {
        let calls=Calls()
        let actions=BrowserPageActions(tabs:{_ in calls.hit();return []},close:{_,_ in calls.hit();return []},
            reading:{_ in fatalError("off feature cannot read browser memory")},wait:{},
            diagnose:{app,_,_,_,_,_ in calls.hit();return .init(app:app,mode:.tabs,tabs:[],duplicates:[])})
        let model=ChromePagesModel(enabled:{false},app:"Fixture",appMemoryKB:nil,gpuKB:nil,actions:actions)
        model.start();model.accept(.init(app:"Fixture",mode:.tabs,tabs:[],duplicates:[]),tabs:[])
        model.loadFixture(before:"/must-not-read",after:"/must-not-read");model.selectRecommended()
        XCTAssertFalse(model.canMeasure)
        await model.work.finish()
        XCTAssertEqual(calls.count,0);XCTAssertNil(model.diagnosis);XCTAssertFalse(model.running)
    }
    func testConfirmedCloseIsKeptAcrossNavigationAndRefusesFeatureStop() async throws {
        let entered=expectation(description:"fake close"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        let process=ProcessIdentity(pid:42,uid:501,started:Date(timeIntervalSince1970:100),executable:"/fixture/browser")
        let tab=ChromeInspector.Tab(window:1,index:1,url:"https://example.test",title:"Fixture",browserID:"fixture",active:false,browserProcess:process)
        let actions=BrowserPageActions(tabs:{_ in []},close:{tabs,_ in
            entered.fulfill();_ = release.wait(timeout:.now()+5)
            return tabs.map{.init(id:$0.selectionID,status:.closed)}
        },reading:{_ in
            let pulse=MachinePulse(load1:0,load5:0,cores:8,thermal:.nominal,memory:.normal,swapUsedMB:0,hogs:[],sampled:Date())
            return .init(pulse:pulse,browserMemoryKB:0)
        },wait:{})
        let model=ChromePagesModel(app:"Fixture",appMemoryKB:nil,gpuKB:nil,actions:actions)
        let session=BrowserSession(availability:FeatureAvailability(enabled:{true}),makeDiagnostics:{gate,_,_,_ in model.work.enabled=gate;return model})
        _=session.diagnostics("Fixture")
        model.close([tab]);await fulfillment(of:[entered],timeout:2)
        session.retireVisibility()
        XCTAssertEqual(session.quitBlocker()?.route,BrowserFeature.route("Fixture"))
        XCTAssertThrowsError(try session.prepareStop());XCTAssertFalse(model.work.stopping)
        release.signal();await model.work.finish()
        XCTAssertNil(model.closing);XCTAssertEqual(model.closeResults.count,1)
        let drain=try session.prepareStop();await drain.finish()
        XCTAssertFalse(session.status.modelLoaded)
    }

}
