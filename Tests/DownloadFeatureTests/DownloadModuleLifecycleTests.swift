import CloudDriveKit
@testable import DownloadKit
import ModuleKit
import XCTest
import NativeFeatureAPI
@testable import DownloadFeature

@MainActor final class DownloadModuleLifecycleTests:XCTestCase {
    private final class Backend:YunXSecretBackend,@unchecked Sendable {
        let lock=NSLock();private var reads=0;private var writes=0
        var onRead:(@Sendable ()->Void)?
        func read()throws->Data? {lock.lock();reads += 1;lock.unlock();onRead?();return nil}
        func write(_ data:Data)throws {lock.lock();writes += 1;lock.unlock()}
        var calls:Int {lock.lock();defer{lock.unlock()};return reads+writes}
    }
    private final class Calls:@unchecked Sendable {
        let lock=NSLock();private var value=0
        func hit(){lock.lock();value += 1;lock.unlock()}
        var count:Int{lock.lock();defer{lock.unlock()};return value}
    }
    private func defaults()->UserDefaults {
        let name="thermo-download-module-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        addTeardownBlock{defaults.removePersistentDomain(forName:name)};return defaults
    }
    private func root()throws->URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-download-module-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock{try? FileManager.default.removeItem(at:root)};return root
    }
    private func model(enabled:@escaping ()->Bool = {true},vault:Backend = Backend(),trackers:Backend = Backend(),jobs:Backend = Backend())throws->YunXDownloadModel {
        let root=try root()
        return YunXDownloadModel(enabled:enabled,vault:YunXVault(backend:vault),settingsStore:YunXSettingsStore(defaults:defaults(),trackers:trackers),jobStore:YunXJobStore(backend:jobs),downloadStore:try DownloadStore(root:root.appendingPathComponent("store")),toolsRoot:{XCTFail("no media tools should start");throw CancellationError()},makeEngine:{_ in XCTFail("no download engine should start");throw CancellationError()})
    }
    func testColdOffNeverReadsKeychainStartsEngineOrSignsIn() async throws {
        let vault=Backend(),trackers=Backend(),jobs=Backend(),model=try model(enabled:{false},vault:vault,trackers:trackers,jobs:jobs)
        XCTAssertEqual(trackers.calls,0)
        model.reloadAccounts();model.reloadAccountsInBackground();model.startBackgroundRefresh();model.restoreJobs()
        await model.authorizeKeychain();await model.refreshAccounts();await model.openCopied("https://example.invalid",passcode:"owned")
        do {try await model.saveLogin(.drive(.quark),secret:"owned");XCTFail("saved disabled login")} catch is CancellationError {}
        do {_ = try await model.sendSms(.xunlei,phone:"owned");XCTFail("sent disabled SMS")} catch is CancellationError {}
        await model.work.finish()
        XCTAssertEqual(vault.calls+trackers.calls+jobs.calls,0)
        XCTAssertTrue(model.link.isEmpty);XCTAssertTrue(model.accounts.isEmpty);XCTAssertNil(model.provider(.quark));XCTAssertTrue(model.canStopFeature)
    }
    func testActiveAccountReadRefusesOffUntilPhysicalReadFinishes() async throws {
        let defaults=defaults(),entered=expectation(description:"fake vault"),release=DispatchSemaphore(value:0),vault=Backend();defer{release.signal()}
        vault.onRead={entered.fulfill();_ = release.wait(timeout:.now()+5)}
        let model=try model(vault:vault)
        let setup=YunXChromeUseSetup(detect:{.init()},run:{_,_,_,_ in 1},defaults:defaults)
        let store=store(model:model,setup:setup)
        _=store.page(route);model.reloadAccountsInBackground();await fulfillment(of:[entered],timeout:2)
        XCTAssertFalse(model.canStopFeature);XCTAssertEqual(store.quitBlocker()?.route,route)
        XCTAssertThrowsError(try store.prepareStop(route.module));XCTAssertFalse(model.work.stopping)
        release.signal();await model.work.finish();XCTAssertTrue(model.canStopFeature)
        if let drain=try store.prepareStop(route.module){await drain.finish()}
        XCTAssertFalse(store.status(route.module).modelLoaded);XCTAssertTrue(model.accounts.isEmpty)
    }
    func testOffSetupDoesNotProbeInstallConnectOrShowLaunchCard() async {
        let calls=Calls(),setup=YunXChromeUseSetup(enabled:{false},detect:{calls.hit();return .init()},run:{_,_,_,_ in calls.hit();return 1},defaults:defaults())
        await setup.refresh();await setup.install();await setup.connect();await setup.offerOnLaunch()
        XCTAssertEqual(calls.count,0);XCTAssertFalse(setup.working)
    }
    func testConfirmedSetupInstallRefusesOffUntilFakeRunnerReturns() async {
        let defaults=defaults(),entered=expectation(description:"fake installer"),release=DispatchSemaphore(value:0);defer{release.signal()}
        let setup=YunXChromeUseSetup(detect:{.init()},run:{_,_,_,_ in
            entered.fulfill();await Task.detached{_ = release.wait(timeout:.now()+5)}.value;return 1
        },defaults:defaults)
        let store=store(model:try! model(),setup:setup)
        _=store.page(route);let install=Task{await setup.install()}
        await fulfillment(of:[entered],timeout:2)
        XCTAssertEqual(store.quitBlocker()?.route,route);XCTAssertThrowsError(try store.prepareStop(route.module))
        release.signal();await install.value
        if let drain=try? store.prepareStop(route.module){await drain.finish()}
        XCTAssertFalse(store.status(route.module).modelLoaded);XCTAssertTrue(setup.output.isEmpty)
    }
    func testDisabledClipboardPromptHasNoTimerOrPanel() {
        let prompt=YunXClipboardPrompt(enabled:{false});prompt.refresh();XCTAssertFalse(prompt.active);prompt.stop();XCTAssertFalse(prompt.active)
    }
    func testOffNavigationAndQuitDoNotInstantiateDownloadsOrSetup() async throws {
        let defaults=defaults();var enabled=false,downloads=0,setups=0
        let fixture=try model(),manifest=BuiltinModuleManifests.download
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in
            DownloadSession(availability:availability,presentation:Presentation(),makeModel:{gate in downloads+=1;fixture.work.enabled=gate;return fixture},makeSetup:{gate in setups+=1;return YunXChromeUseSetup(enabled:gate,detect:{.init()},run:{_,_,_,_ in 1},defaults:defaults)})
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in enabled})
        XCTAssertNil(store.page(route));store.start(route.module);store.shutdown(route.module)
        XCTAssertNil(store.quitBlocker());XCTAssertEqual(downloads+setups,0)
        enabled=true;_=store.page(route)
        fixture.link="owned";fixture.passcode="owned";fixture.settings.trackers=["owned tracker"]
        if let drain=try store.prepareStop(route.module){await drain.finish()}
        XCTAssertFalse(store.status(route.module).modelLoaded);XCTAssertTrue(fixture.link.isEmpty);XCTAssertTrue(fixture.passcode.isEmpty);XCTAssertTrue(fixture.settings.trackers.isEmpty)
        fixture.reloadAccounts();XCTAssertEqual(fixture.work.count,0)
    }
    func testPrewarmProbesSetupWithoutConstructingDownloadModelOrStartingClipboard() async throws {
        let defaults=defaults(),fixture=try model(),calls=Calls()
        let setup=YunXChromeUseSetup(detect:{calls.hit();return .init(tool:"/fixture/chrome-use",connected:true)},run:{_,_,_,_ in XCTFail("no installer");return 1},defaults:defaults)
        var creations=0
        let manifest=BuiltinModuleManifests.download
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in
            DownloadSession(availability:availability,presentation:Presentation(),makeModel:{gate in creations+=1;fixture.work.enabled=gate;return fixture},makeSetup:{gate in setup.work.enabled=gate;return setup},makePrompt:{_,_,_ in YunXClipboardPrompt(enabled:{false})})
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true})
        store.start(manifest.id);store.start(manifest.id)
        await setup.work.finish()
        XCTAssertEqual(creations,0);XCTAssertEqual(calls.count,1)
        XCTAssertNil(store.quitBlocker());store.shutdown(manifest.id)
    }
    private let route=NativeFeatureRoute(BuiltinModuleManifests.download.id,"home")
    private final class Presentation:DownloadPresentation {
        var mainWindowActive:Bool {false}
        func showDownloadPage(){XCTFail("unexpected navigation")}
    }
    private func store(model:YunXDownloadModel,setup:YunXChromeUseSetup)->NativeFeatureStore {
        let definition=NativeFeatureDefinition(manifest:BuiltinModuleManifests.download,makeSession:{availability in
            DownloadSession(availability:availability,presentation:Presentation(),makeModel:{gate in model.work.enabled=gate;return model},makeSetup:{gate in setup.work.enabled=gate;return setup})
        })
        return NativeFeatureStore(definitions:[definition],enabled:{_ in true})
    }
}
