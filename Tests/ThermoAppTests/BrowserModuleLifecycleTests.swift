import XCTest
import ModuleKit
@testable import CleanKit
@testable import ThermoApp

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
    func testRegistryOwnsDynamicBrowserNamesAndGenericRoute() {
        XCTAssertTrue(BuiltinModules.problems.isEmpty,BuiltinModules.problems.joined(separator:"\n"))
        XCTAssertFalse(HostPageSpecification.pages.contains{$0.argument=="pages"})
        for app in ["Google Chrome","Arc","Microsoft Edge"] {
            let page=MainPage.browser(app)
            XCTAssertEqual(page.module,BrowserModule.manifest.id)
            XCTAssertEqual(BuiltinModules.page(page)?.module.id,BrowserModule.manifest.id)
            XCTAssertEqual(BuiltinModules.page(page)?.entry.scene,"pages")
        }
        XCTAssertEqual(BuiltinModules.page(.module(BrowserModule.manifest.id,""))?.target,.browser("Google Chrome"))
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
        XCTAssertNil(model.inventory);XCTAssertFalse(TabWorkspaceModel.loadedApps.contains("Fixture"))
    }
    func testAcceptedRestoreRefusesFeatureStopAndQuitUntilItReturns() async throws {
        let calls=Calls(),entered=expectation(description:"restore"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        var actions=actions(calls)
        actions.restore={_,_ in entered.fulfill();_ = release.wait(timeout:.now()+5);return .init(name:"Fixture",app:"Fixture",entries:[])}
        let model=TabWorkspaceModel(app:"Fixture",actions:actions)
        let models=AppModels(defaults:defaults(),makeWorkspace:{gate,_ in model.work.enabled=gate;return model})
        _=models.workspace("Fixture")
        model.restore(.init(name:"Fixture",app:"Fixture",entries:[]))
        await fulfillment(of:[entered],timeout:2)
        XCTAssertEqual(models.browserExitBlocker(),.browser("Fixture"))
        XCTAssertThrowsError(try BrowserModule.prepareStop(models:models));XCTAssertFalse(model.work.stopping)
        release.signal();await model.work.finish()
        XCTAssertNil(models.browserExitBlocker())
        if let finish=try BrowserModule.prepareStop(models:models){await finish()}
        XCTAssertFalse(models.browsersLoaded)
        XCTAssertGreaterThan(calls.count,0,"the post-action refresh also drains")
    }
    func testOffNavigationDoesNotInstantiateAndReenableCannotReviveOldModels() async throws {
        let defaults=defaults(),calls=Calls();var creations=0
        let models=AppModels(defaults:defaults,makeWorkspace:{gate,app in creations += 1;return TabWorkspaceModel(enabled:gate,app:app,actions:self.actions(calls))})
        let center=ModuleCenter(defaults:defaults,prepareBuiltinStop:{_ in try BrowserModule.prepareStop(models:models)})
        center.setEnabled(BrowserModule.manifest.id,false)
        models.stopBrowserChecks()
        XCTAssertFalse(center.shows(.browser("Arc")));XCTAssertFalse(models.browsersLoaded);XCTAssertEqual(creations,0)
        defaults.set(true,forKey:ModulePreferences.key(BrowserModule.manifest.id))
        let old=models.workspace("Fixture")
        if let finish=try BrowserModule.prepareStop(models:models){await finish()}
        old.refresh();XCTAssertEqual(old.work.count,0)
        let fresh=models.workspace("Fixture")
        XCTAssertFalse(old === fresh);XCTAssertEqual(creations,2)
        fresh.refresh();await fresh.work.finish();XCTAssertEqual(calls.count,2)
        if let finish=try BrowserModule.prepareStop(models:models){await finish()}
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

}
