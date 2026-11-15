import AgentDoctor
@testable import CleanKit
import ModuleKit
import NativeFeatureAPI
import XCTest
@testable import ClaudeFeature

@MainActor final class ClaudeToolsModuleLifecycleTests:XCTestCase {
    private final class Calls:@unchecked Sendable {
        let lock=NSLock();private var value=0
        func hit(){lock.lock();value += 1;lock.unlock()}
        var count:Int{lock.lock();defer{lock.unlock()};return value}
    }
    private func root()throws->URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-claude-module-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock{try? FileManager.default.removeItem(at:root)};return root
    }
    private func defaults()->UserDefaults {
        let name="thermo-claude-module-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        addTeardownBlock{defaults.removePersistentDomain(forName:name)};return defaults
    }
    func testOffAccountsCannotListCreateLaunchOrCopy() async throws {
        let root=try root(),calls=Calls(),service=ClaudeProfiles(home:root,keychainHasItem:{_ in calls.hit();return false},alive:{_ in calls.hit();return false})
        let model=ClaudeAccountsModel(enabled:{false},profiles:service)
        model.refresh();XCTAssertNotNil(model.create(name:"fixture"))
        let profile=ClaudeProfile(name:"fixture",directory:root.appendingPathComponent(".claude-fixture").path,isDefault:false,signedIn:false,liveSessions:0)
        model.open(profile);model.copy(profile);await model.work.finish()
        XCTAssertEqual(calls.count,0);XCTAssertFalse(model.loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath:profile.directory))
    }
    func testStopDrainsAccountScanAndDropsLateProfiles() async throws {
        let root=try root(),entered=expectation(description:"account read"),release=DispatchSemaphore(value:0)
        defer{release.signal()}
        let service=ClaudeProfiles(home:root,keychainHasItem:{_ in entered.fulfill();_ = release.wait(timeout:.now()+5);return false},alive:{_ in false})
        let model=ClaudeAccountsModel(profiles:service);model.refresh()
        await fulfillment(of:[entered],timeout:2);model.stopFeature()
        release.signal();await model.finishFeatureStop()
        XCTAssertFalse(model.loaded);XCTAssertTrue(model.profiles.isEmpty)
    }
    func testOffCleanupCannotScanOrCreatePrivacyServices() async throws {
        let calls=Calls(),model=ClaudeCleanupModel(enabled:{false},scan:{calls.hit();return([],[])},makePrivacy:{gate in calls.hit();return PrivacyToolsModel(enabled:gate)})
        model.scan();model.reset([]);await model.work.finish()
        XCTAssertEqual(calls.count,0);XCTAssertFalse(model.loaded)
        model.stopFeature();await model.finishFeatureStop();XCTAssertEqual(calls.count,0)
    }
    func testCleanupScanDrainsWithoutPublishingAfterOff() async throws {
        let entered=expectation(description:"cleanup read"),release=DispatchSemaphore(value:0);defer{release.signal()}
        let model=ClaudeCleanupModel(scan:{entered.fulfill();_ = release.wait(timeout:.now()+5);return([],[])})
        model.scan();await fulfillment(of:[entered],timeout:2);model.stopFeature()
        var finished=false;let drain=Task{await model.finishFeatureStop();finished=true}
        await Task.yield();XCTAssertFalse(finished);release.signal();await drain.value
        XCTAssertFalse(model.loaded);XCTAssertFalse(model.busy);XCTAssertTrue(model.candidates.isEmpty)
    }
    func testConfirmedPrivacyChangeRefusesOffAndQuitUntilDone() async throws {
        let root=try root(),defaults=defaults(),entered=expectation(description:"owned action"),release=DispatchSemaphore(value:0);defer{release.signal()}
        let privacy=PrivacyToolsModel(service:.init(home:root,runner:{_,_ in XCTFail("no actual settings commands");return .init(status:1)}))
        let cleanup=ClaudeCleanupModel(scan:{([],[])},makePrivacy:{gate in privacy.work.enabled=gate;return privacy})
        let manifest=BuiltinModuleManifests.claude
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in
            ClaudeSession(availability:availability,makeCleanup:{gate in cleanup.work.enabled=gate;return cleanup})
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true})
        _=store.page(.init(manifest.id,"privacy"));_=cleanup.privacy
        privacy.perform{_ in entered.fulfill();_ = release.wait(timeout:.now()+5);return "owned fixture"}
        await fulfillment(of:[entered],timeout:2)
        XCTAssertEqual(store.quitBlocker()?.route,NativeFeatureRoute(manifest.id,"privacy"))
        XCTAssertThrowsError(try store.prepareStop(manifest.id));XCTAssertFalse(cleanup.work.stopping)
        release.signal();await privacy.work.finish();XCTAssertEqual(privacy.result,"owned fixture")
        if let drain=try store.prepareStop(manifest.id){await drain.finish()}
        XCTAssertFalse(store.status(manifest.id).modelLoaded);XCTAssertNil(privacy.result)
    }
    func testColdOffPrivacyNeverScansLooksUpOrRunsAnAction() async throws {
        let root=try root(),calls=Calls(),privacy=PrivacyToolsModel(enabled:{false},service:.init(home:root),inspect:{calls.hit();return[]},lookup:{calls.hit();throw CancellationError()})
        privacy.inspect();privacy.lookup();privacy.perform{_ in calls.hit();return "unexpected"}
        await privacy.work.finish();XCTAssertEqual(calls.count,0);XCTAssertFalse(privacy.busy)
    }
    func testOffNavigationCreatesNothingAndReenableUsesFreshModels() async throws {
        let root=try root();var enabled=false,accounts=0,models:[ClaudeCleanupModel]=[]
        let manifest=BuiltinModuleManifests.claude
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in
            ClaudeSession(availability:availability,makeAccounts:{gate in accounts += 1;return ClaudeAccountsModel(enabled:gate,profiles:ClaudeProfiles(home:root,keychainHasItem:{_ in false},alive:{_ in false}))},makeCleanup:{gate in
                let model=ClaudeCleanupModel(enabled:gate,scan:{([],[])});models.append(model);return model
            })
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in enabled})
        XCTAssertNil(store.page(.init(manifest.id,"accounts")));XCTAssertFalse(store.status(manifest.id).modelLoaded)
        XCTAssertEqual(accounts+models.count,0)
        enabled=true;_=store.page(.init(manifest.id,"reset"));let old=try XCTUnwrap(models.first)
        old.scan();await old.work.finish();XCTAssertTrue(old.loaded)
        if let drain=try store.prepareStop(manifest.id){await drain.finish()}
        old.scan();XCTAssertEqual(old.work.count,0)
        _=store.page(.init(manifest.id,"reset"));let fresh=try XCTUnwrap(models.last)
        XCTAssertFalse(old === fresh);XCTAssertEqual(models.count,2);XCTAssertEqual(accounts,0)
        if let drain=try store.prepareStop(manifest.id){await drain.finish()}
    }
    func testResetRefusesOffAndQuitUntilTheReviewedOperationReturns() async throws {
        let root=try root(),defaults=defaults(),entered=expectation(description:"fake reset"),release=DispatchSemaphore(value:0);defer{release.signal()}
        let candidate=ClaudeResetCandidate(target:.settings,path:root.appendingPathComponent("settings.json").path,status:.available,reason:nil,bytes:0,snapshot:"owned")
        let cleanup=ClaudeCleanupModel(scan:{([],[])},reset:{plan in
            XCTAssertEqual(plan.count,1);entered.fulfill();_ = release.wait(timeout:.now()+5)
            return ClaudeResetResult(batch:nil,succeeded:[.settings],failed:[:])
        })
        let manifest=BuiltinModuleManifests.claude
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in
            ClaudeSession(availability:availability,makeCleanup:{gate in cleanup.work.enabled=gate;return cleanup})
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true})
        _=store.page(.init(manifest.id,"reset"));cleanup.reset([candidate]);await fulfillment(of:[entered],timeout:2)
        XCTAssertEqual(store.quitBlocker()?.route,NativeFeatureRoute(manifest.id,"reset"))
        XCTAssertThrowsError(try store.prepareStop(manifest.id));XCTAssertFalse(cleanup.work.stopping)
        release.signal();await cleanup.work.finish()
        if let drain=try store.prepareStop(manifest.id){await drain.finish()}
        XCTAssertFalse(store.status(manifest.id).modelLoaded);XCTAssertNil(cleanup.outcome)
    }
    private nonisolated static var report:ClaudeLocalReport {
        try! JSONDecoder().decode(ClaudeLocalReport.self,from:Data(#"{"schemaVersion":1,"kind":"fixture","generatedAt":"fixture","platform":"fixture","readOnly":true,"networkPerformed":false,"complete":true,"checks":[]}"#.utf8))
    }
    func testDisabledDiagnosticsDoesNotRead() async {
        let calls=Calls(),model=ClaudeDiagnosticsModel(enabled:{false},scan:{calls.hit();return Self.report})
        model.scan();await model.work.finish();XCTAssertEqual(calls.count,0);XCTAssertNil(model.report)
    }
    func testLateDiagnosticsAreDroppedAfterStop() async {
        let entered=expectation(description:"diagnostics"),release=DispatchSemaphore(value:0);defer{release.signal()}
        let model=ClaudeDiagnosticsModel(scan:{entered.fulfill();_ = release.wait(timeout:.now()+5);return Self.report})
        model.scan();await fulfillment(of:[entered],timeout:2);model.stopFeature();release.signal()
        await model.finishFeatureStop();XCTAssertNil(model.report);XCTAssertFalse(model.scanning)
    }

}
