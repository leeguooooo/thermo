import AgentCore
import ModuleKit
import XCTest
@testable import ThermoApp

@MainActor final class PluginsModuleLifecycleTests:XCTestCase {
    private final class Calls:@unchecked Sendable {
        let lock=NSLock();private var value=0
        func hit(){lock.lock();value += 1;lock.unlock()}
        var count:Int{lock.lock();defer{lock.unlock()};return value}
    }
    private func root()throws->URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-plugins-test-"+UUID().uuidString)
        addTeardownBlock{try? FileManager.default.removeItem(at:root)};return root
    }
    private func defaults()->UserDefaults {
        let name="thermo-plugins-test-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        addTeardownBlock{defaults.removePersistentDomain(forName:name)};return defaults
    }
    private nonisolated static var market:Data {Data(#"{"name":"leeguooooo-plugins","plugins":[{"name":"fixture","version":"1.0.0"}]}"#.utf8)}
    private func record()throws->PluginRecord {
        let market=try XCTUnwrap(Marketplace.decode(Self.market))
        return try XCTUnwrap(PluginRecords.build(market,installed:[],use:.init()).first)
    }
    func testRegistryOwnsBothPageForms() {
        XCTAssertTrue(BuiltinModules.problems.isEmpty)
        XCTAssertEqual(MainPage.plugins.module,PluginsModule.manifest.id)
        XCTAssertEqual(BuiltinModules.page(.module(PluginsModule.manifest.id,"home"))?.target,.plugins)
    }
    func testColdOffDoesNotFetchReadDiskCheckUpdatesOrInstall() async throws {
        let calls=Calls(),root=try root()
        let model=PluginsModel(enabled:{false},cache:.init(directory:root),marketplaceKnown:{calls.hit();return false},fetch:{calls.hit();return Self.market},readState:{state in calls.hit();return(state,true,true,[])},check:{calls.hit();return nil},perform:{_ in calls.hit();return nil})
        model.open();model.refresh();model.install(try record());model.installUse();await model.work.finish()
        XCTAssertEqual(calls.count,0);XCTAssertFalse(model.loaded);XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
    }
    func testStoppedFetchCannotWriteCacheOrBeginLocalScan() async throws {
        let entered=expectation(description:"fetch"),release=DispatchSemaphore(value:0),calls=Calls(),root=try root()
        defer{release.signal()}
        let model=PluginsModel(cache:.init(directory:root),fetch:{
            entered.fulfill();await Task.detached{_ = release.wait(timeout:.now()+5)}.value;return Self.market
        },readState:{state in calls.hit();return(state,true,true,[])},check:{calls.hit();return nil})
        model.open();await fulfillment(of:[entered],timeout:2);model.stopFeature()
        var finished=false;let drain=Task{await model.finishFeatureStop();finished=true}
        await Task.yield();XCTAssertFalse(finished)
        release.signal();await drain.value
        XCTAssertEqual(calls.count,0);XCTAssertFalse(model.loaded);XCTAssertTrue(model.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
    }
    func testInstallRefusesOffAndQuitUntilOwnedBackendReturns() async throws {
        let entered=expectation(description:"fake install"),release=DispatchSemaphore(value:0),defaults=defaults(),root=try root(),calls=Calls()
        defer{release.signal()}
        let model=PluginsModel(cache:.init(directory:root),marketplaceKnown:{true},fetch:{nil},readState:{($0,true,true,[])},check:{nil},perform:{steps in
            XCTAssertFalse(steps.isEmpty);calls.hit();entered.fulfill()
            await Task.detached{_ = release.wait(timeout:.now()+5)}.value;return nil
        })
        let models=AppModels(defaults:defaults,makePlugins:{gate in model.work.enabled=gate;return model})
        _=models.plugins;model.install(try record());await fulfillment(of:[entered],timeout:2)
        XCTAssertEqual(models.pluginsExitBlocker(),.plugins)
        XCTAssertThrowsError(try PluginsModule.prepareStop(models:models));XCTAssertFalse(model.work.stopping)
        release.signal();await model.work.finish();XCTAssertEqual(calls.count,1)
        if let finish=try PluginsModule.prepareStop(models:models){await finish()}
        XCTAssertFalse(models.pluginsLoaded);XCTAssertTrue(model.records.isEmpty)
    }
    func testOffNavigationStaysColdAndReenableCreatesNewModel() async throws {
        let defaults=defaults(),root=try root();var creations=0
        let models=AppModels(defaults:defaults,makePlugins:{gate in
            creations += 1;return PluginsModel(enabled:gate,cache:.init(directory:root),fetch:{nil},readState:{($0,true,true,[])},check:{nil})
        })
        let center=ModuleCenter(defaults:defaults,prepareBuiltinStop:{_ in try PluginsModule.prepareStop(models:models)})
        center.setEnabled(PluginsModule.manifest.id,false)
        XCTAssertFalse(center.shows(.plugins));XCTAssertFalse(models.pluginsLoaded);XCTAssertEqual(creations,0)
        defaults.set(true,forKey:ModulePreferences.key(PluginsModule.manifest.id))
        let old=models.plugins;old.open();await old.work.finish();XCTAssertTrue(old.loaded)
        if let finish=try PluginsModule.prepareStop(models:models){await finish()}
        old.open();XCTAssertEqual(old.work.count,0)
        let fresh=models.plugins;XCTAssertFalse(old === fresh);XCTAssertEqual(creations,2);XCTAssertFalse(fresh.loaded)
        if let finish=try PluginsModule.prepareStop(models:models){await finish()}
    }
}
