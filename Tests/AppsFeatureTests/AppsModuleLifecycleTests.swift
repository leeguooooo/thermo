import AgentCore
import AppKit
@testable import CleanKit
import ModuleKit
import XCTest
@testable import AppsFeature
import NativeFeatureAPI

@MainActor final class AppsModuleLifecycleTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock=NSLock();private var value=0
        func hit(){lock.lock();value += 1;lock.unlock()}
        var count:Int{lock.lock();defer{lock.unlock()};return value}
    }
    private actor Gate {
        var released=false;var continuation:CheckedContinuation<Void,Never>?
        func wait() async {if !released {await withCheckedContinuation{continuation=$0}}}
        func release(){released=true;continuation?.resume();continuation=nil}
    }
    private func source()->NativeUpdateSource {
        NativeUpdateSource(app:InstalledApp(path:"/fixture.app",name:"Fixture",bundleID:"com.example.fixture"),kind:"sparkle")
    }

    func testColdOffBlocksInventoriesPermissionsNetworkAndMutations() async {
        let calls=Calls(),app=InstalledApp(path:"/fixture.app",name:"Fixture",bundleID:nil)
        let apps=AppsModel(inventory:{_ in calls.hit();return []},reviewPlan:{app,_,_,_ in calls.hit();return .init(app:app,paths:[],bytes:0)},remove:{_ in calls.hit();return CleanResult(id:"fixture",trashed:true)},readOrphans:{_ in calls.hit();return []})
        let startup=StartupItemsModel(read:{calls.hit();return .init(items:[],issues:[])},change:{_,_ in calls.hit()},readBackground:{calls.hit();return .requiresAuthorization})
        let updates=AppUpdatesModel(read:{_ in calls.hit();return .init()},install:{item in calls.hit();return .init(token:item.token,outcome:"failed",message:"fixture")})
        let native=NativeUpdatesModel(discovery:{_ in calls.hit();return .init(sources:[])},checker:{source in calls.hit();return .init(source:source,status:"cancelled",message:"fixture")},installer:{_ in calls.hit();return .init(outcome:"failed",message:"fixture")},recoveryReader:{calls.hit();return .init()})
        let home=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:home)}
        let store=AppStoreModel(cache:StoreCache(home:home.path),fetch:{calls.hit();return nil})
        let session=AppsFeatureModels(apps:apps,startup:startup,updates:updates,native:native,store:store)
        session.setEnabled{false}
        apps.load();apps.scanOrphans();apps.review(app);apps.uninstall(.init(app:app,paths:[],bytes:0))
        startup.refresh();startup.inspectBackground();startup.apply(.init(path:"/fixture",label:"fixture",enabled:true))
        updates.refresh(catalog:true)
        updates.apply(.init(token:"fixture",name:"Fixture",installedVersions:["1"],targetVersion:"2",appPaths:["/fixture.app"],bundleIDs:[:],identities:[:],definition:"fixture",brew:"/fixture",brewIdentity:"fixture"))
        native.load();native.refreshRecovery();native.checkAll([source()]);native.install(.init(source:source(),status:"available",message:"fixture"))
        store.open();store.refresh()
        await Task.yield()
        XCTAssertEqual(calls.count,0)
        XCTAssertFalse(apps.loading || apps.working || startup.loading || startup.working || startup.authorizing || updates.loading || native.loading || native.installing || store.loading)
        XCTAssertNil(apps.planning)
        XCTAssertTrue(session.beginStopping());await session.finishStopping()
    }

    func testStoppingWaitsForUncooperativeReadAndDropsItsResult() async {
        let entered=expectation(description:"update catalog entered"),release=DispatchSemaphore(value:0),calls=Calls()
        defer{release.signal()}
        let updates=AppUpdatesModel(read:{_ in calls.hit();entered.fulfill();_ = release.wait(timeout:.now()+5);return .init()})
        let session=AppsFeatureModels(updates:updates)
        updates.refresh();await fulfillment(of:[entered],timeout:2)
        XCTAssertTrue(session.beginStopping())
        var finished=false;let finish=Task{await session.finishStopping();finished=true}
        await Task.yield();XCTAssertFalse(finished)
        updates.refresh(catalog:true);XCTAssertEqual(calls.count,1)
        release.signal();await finish.value
        XCTAssertNil(updates.report);XCTAssertEqual(updates.work.count,0)
    }
    func testConfirmedRemovalRefusesFeatureStopUntilItFinishes() async {
        let entered=expectation(description:"fixture removal entered"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        let apps=AppsModel(remove:{_ in entered.fulfill();_ = release.wait(timeout:.now()+5);return CleanResult(id:"fixture",trashed:true)})
        let session=AppsFeatureModels(apps:apps)
        apps.uninstall(.init(app:InstalledApp(path:"/fixture.app",name:"Fixture",bundleID:nil),paths:[],bytes:0))
        await fulfillment(of:[entered],timeout:2)
        XCTAssertFalse(session.beginStopping());XCTAssertFalse(apps.work.stopping)
        release.signal();await apps.work.finish()
        XCTAssertTrue(session.beginStopping());await session.finishStopping()
        XCTAssertFalse(apps.working)
    }
    func testNativeTransactionKeepsTheFeatureOnAndExcludesAnotherUpdater() async {
        let gate=Gate(),entered=expectation(description:"native transaction entered"),calls=Calls()
        let native=NativeUpdatesModel(read:{_ in []},installer:{_ in entered.fulfill();await gate.wait();return .init(outcome:"failed",message:"fixture")},recoveryReader:{.init()})
        let updates=AppUpdatesModel(read:{_ in .init()},install:{item in calls.hit();return .init(token:item.token,outcome:"failed",message:"fixture")})
        let session=AppsFeatureModels(updates:updates,native:native)
        native.install(.init(source:source(),status:"available",message:"fixture"))
        await fulfillment(of:[entered],timeout:2)
        XCTAssertFalse(session.beginStopping())
        updates.apply(.init(token:"fixture",name:"Fixture",installedVersions:["1"],targetVersion:"2",appPaths:["/fixture.app"],bundleIDs:[:],identities:[:],definition:"fixture",brew:"/fixture",brewIdentity:"fixture"))
        XCTAssertFalse(updates.working);XCTAssertEqual(calls.count,0)
        await gate.release();await native.work.finish()
        XCTAssertTrue(session.beginStopping());await session.finishStopping()
    }
    func testCancelledCatalogCannotWriteOrPublishAfterStopping() async {
        let home=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),gate=Gate(),entered=expectation(description:"catalog request entered")
        defer{try? FileManager.default.removeItem(at:home)}
        let cache=StoreCache(home:home.path)
        let model=AppStoreModel(cache:cache,fetch:{entered.fulfill();await gate.wait();return Data("{\"apps\":[{\"id\":\"fixture\",\"title\":\"Fixture\",\"url\":\"https://example.test\"}]}".utf8)})
        model.refresh();await fulfillment(of:[entered],timeout:2)
        model.stopFeature()
        var finished=false;let finish=Task{await model.finishFeatureStop();finished=true}
        await Task.yield();XCTAssertFalse(finished)
        await gate.release();await finish.value
        XCTAssertNil(cache.read("app-store.json"));XCTAssertTrue(model.apps.isEmpty);XCTAssertFalse(model.loaded)
    }

    func testReenableCreatesFreshModelsAfterPhysicalRetirement() async throws {
        let name="thermo-apps-reopen-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        var creations=0
        var sessions:[AppsFeatureSession]=[]
        let definition=NativeFeatureDefinition(manifest:BuiltinModuleManifests.apps,makeSession:{availability in
            creations += 1
            let session=AppsFeatureSession(availability:availability,makeModels:{AppsFeatureModels(apps:AppsModel(inventory:{_ in []}))})
            sessions.append(session);return session
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in defaults.bool(forKey:ModulePreferences.key(BuiltinModuleManifests.apps.id))})
        defaults.set(true,forKey:ModulePreferences.key(BuiltinModuleManifests.apps.id))
        _=store.page(.init(BuiltinModuleManifests.apps.id,"installed"))
        let original=sessions[0].models.apps
        defaults.set(false,forKey:ModulePreferences.key(BuiltinModuleManifests.apps.id))
        let stopping=try store.prepareStop(BuiltinModuleManifests.apps.id)
        let finish=try XCTUnwrap(stopping);await finish.finish()
        XCTAssertFalse(store.status(BuiltinModuleManifests.apps.id).modelLoaded)
        original.load();XCTAssertFalse(original.loading)
        defaults.set(true,forKey:ModulePreferences.key(BuiltinModuleManifests.apps.id))
        _=store.page(.init(BuiltinModuleManifests.apps.id,"installed"))
        XCTAssertFalse(sessions[1].models.apps === original);XCTAssertEqual(creations,2)
        if let stop=try store.prepareStop(BuiltinModuleManifests.apps.id){await stop.finish()}
    }
}
