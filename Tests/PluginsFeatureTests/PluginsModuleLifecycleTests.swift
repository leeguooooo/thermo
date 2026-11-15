import AgentCore
import ModuleKit
import NativeFeatureAPI
import XCTest
@testable import PluginsFeature

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
        let manifest=BuiltinModuleManifests.plugins
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in
            PluginsSession(availability:availability,navigate:{_ in XCTFail("unexpected navigation")},makeModel:{gate in model.work.enabled=gate;return model})
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true})
        _=store.page(.init(manifest.id,"home"));model.install(try record());await fulfillment(of:[entered],timeout:2)
        XCTAssertEqual(store.quitBlocker()?.route,NativeFeatureRoute(manifest.id,"home"))
        XCTAssertThrowsError(try store.prepareStop(manifest.id));XCTAssertFalse(model.work.stopping)
        release.signal();await model.work.finish();XCTAssertEqual(calls.count,1)
        if let drain=try store.prepareStop(manifest.id){await drain.finish()}
        XCTAssertFalse(store.status(manifest.id).modelLoaded);XCTAssertTrue(model.records.isEmpty)
    }
    func testOffNavigationStaysColdAndReenableCreatesNewModel() async throws {
        let root=try root();var enabled=false,models:[PluginsModel]=[]
        let manifest=BuiltinModuleManifests.plugins
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in
            PluginsSession(availability:availability,navigate:{_ in XCTFail("unexpected navigation")},makeModel:{gate in
                let model=PluginsModel(enabled:gate,cache:.init(directory:root),fetch:{nil},readState:{($0,true,true,[])},check:{nil})
                models.append(model);return model
            })
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in enabled}),route=NativeFeatureRoute(manifest.id,"home")
        XCTAssertNil(store.page(route));store.retireVisibility();XCTAssertNil(store.quitBlocker());XCTAssertFalse(store.status(manifest.id).modelLoaded);XCTAssertTrue(models.isEmpty)
        enabled=true;XCTAssertNotNil(store.page(route))
        let old=try XCTUnwrap(models.first);old.open();await old.work.finish();XCTAssertTrue(old.loaded)
        if let drain=try store.prepareStop(manifest.id){await drain.finish()}
        old.open();XCTAssertEqual(old.work.count,0)
        XCTAssertNotNil(store.page(route));let fresh=try XCTUnwrap(models.last)
        XCTAssertFalse(old === fresh);XCTAssertEqual(models.count,2);XCTAssertFalse(fresh.loaded)
        if let drain=try store.prepareStop(manifest.id){await drain.finish()}
    }
}
