import CloudDriveKit
@testable import DownloadKit
import ModuleKit
import XCTest
@testable import ThermoApp

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
    func testRegistryOwnsLegacyAndGenericDownloadPages() {
        XCTAssertTrue(BuiltinModules.problems.isEmpty)
        XCTAssertEqual(MainPage.yunx.module,DownloadModule.manifest.id)
        XCTAssertEqual(BuiltinModules.page(.module(DownloadModule.manifest.id,"home"))?.target,.yunx)
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
        let models=AppModels(defaults:defaults,makeDownload:{gate in model.work.enabled=gate;return model})
        _=models.download;model.reloadAccountsInBackground();await fulfillment(of:[entered],timeout:2)
        XCTAssertFalse(model.canStopFeature);XCTAssertEqual(models.downloadExitBlocker(),.yunx)
        XCTAssertThrowsError(try DownloadModule.prepareStop(models:models));XCTAssertFalse(model.work.stopping)
        release.signal();await model.work.finish();XCTAssertTrue(model.canStopFeature)
        if let finish=try DownloadModule.prepareStop(models:models){await finish()}
        XCTAssertFalse(models.downloadLoaded);XCTAssertTrue(model.accounts.isEmpty)
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
        let models=AppModels(defaults:defaults,makeDownloadSetup:{gate in setup.work.enabled=gate;return setup})
        _=models.downloadSetup;let install=Task{await setup.install()}
        await fulfillment(of:[entered],timeout:2)
        XCTAssertEqual(models.downloadExitBlocker(),.yunx);XCTAssertThrowsError(try DownloadModule.prepareStop(models:models))
        release.signal();await install.value
        if let finish=try? DownloadModule.prepareStop(models:models){await finish()}
        XCTAssertFalse(models.downloadSetupLoaded);XCTAssertTrue(setup.output.isEmpty)
    }
    func testDisabledClipboardPromptHasNoTimerOrPanel() {
        let prompt=YunXClipboardPrompt(enabled:{false});prompt.refresh();XCTAssertFalse(prompt.active);prompt.stop();XCTAssertFalse(prompt.active)
    }
    func testOffNavigationAndQuitDoNotInstantiateDownloadsOrSetup() async throws {
        let defaults=defaults();var downloads=0,setups=0
        let fixture=try model()
        let models=AppModels(defaults:defaults,makeDownload:{gate in downloads += 1;fixture.work.enabled=gate;return fixture},makeDownloadSetup:{gate in setups += 1;return YunXChromeUseSetup(enabled:gate,detect:{.init()},run:{_,_,_,_ in 1},defaults:defaults)})
        let center=ModuleCenter(defaults:defaults,prepareBuiltinStop:{_ in try DownloadModule.prepareStop(models:models)})
        center.setEnabled(DownloadModule.manifest.id,false);models.shutdownDownloadIfLoaded()
        XCTAssertFalse(center.shows(.yunx));XCTAssertEqual(downloads+setups,0)
        defaults.set(true,forKey:ModulePreferences.key(DownloadModule.manifest.id));_ = models.download
        fixture.link="owned";fixture.passcode="owned";fixture.settings.trackers=["owned tracker"]
        if let finish=try DownloadModule.prepareStop(models:models){await finish()}
        XCTAssertFalse(models.downloadLoaded);XCTAssertTrue(fixture.link.isEmpty);XCTAssertTrue(fixture.passcode.isEmpty);XCTAssertTrue(fixture.settings.trackers.isEmpty)
        fixture.reloadAccounts();XCTAssertEqual(fixture.work.count,0)
    }
}
