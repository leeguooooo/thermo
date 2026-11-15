import ModuleKit
import XCTest
@testable import CleanKit
@testable import ThermoApp

@MainActor final class CheckupModuleLifecycleTests:XCTestCase {
    private final class Calls:@unchecked Sendable {
        private let lock=NSLock();private var value=0
        func hit(){lock.lock();value += 1;lock.unlock()}
        var count:Int{lock.lock();defer{lock.unlock()};return value}
    }
    private func defaults()->UserDefaults {
        let name="thermo-checkup-module-"+UUID().uuidString
        let settings=UserDefaults(suiteName:name)!
        addTeardownBlock{settings.removePersistentDomain(forName:name)}
        return settings
    }
    private nonisolated static func report()->CheckupReport {.init(overall:.good,summary:"Fixture",findings:[],source:"fixture",made:Date())}
    private nonisolated static var backend:LocalAIBackend {.http(name:"Fixture",base:URL(string:"https://example.invalid")!,model:"Fixture")}
    func testRegistryOwnsLegacyAndGenericCheckupPages() {
        XCTAssertTrue(BuiltinModules.problems.isEmpty,BuiltinModules.problems.joined(separator:"\n"))
        XCTAssertEqual(MainPage.checkup.module,CheckupModule.manifest.id)
        XCTAssertEqual(BuiltinModules.page(.checkup)?.target,.checkup)
        XCTAssertEqual(BuiltinModules.page(.module(CheckupModule.manifest.id,"home"))?.target,.checkup)
    }
    func testColdOffCannotMeasureReadFixtureDiscoverBackendOrGrantConsent() async {
        let defaults=defaults(),calls=Calls()
        let model=CheckupModel(enabled:{false},defaults:defaults,measure:{_,_ in calls.hit();return .init()},backend:{calls.hit();return Self.backend},asker:{_,_ in calls.hit();return Self.report()})
        model.start(reading:nil);model.send();model.consented=true;model.loadFixture(answer:"/must-not-read")
        await model.work.finish()
        XCTAssertEqual(calls.count,0);XCTAssertFalse(defaults.bool(forKey:"localAI.checkupConsented"))
        XCTAssertNil(model.snapshot);XCTAssertNil(model.report);XCTAssertEqual(model.phase,.idle)
    }
    func testFirstRunWaitsForPreviewAndExplicitSendWithoutAnyRealAIRequest() async {
        let defaults=defaults(),calls=Calls()
        let model=CheckupModel(defaults:defaults,measure:{_,_ in .init(model:"Fixture")},backend:{Self.backend},asker:{_,_ in calls.hit();return Self.report()})
        model.start(reading:nil);await model.work.finish()
        XCTAssertEqual(model.phase,.preview);XCTAssertEqual(calls.count,0);XCTAssertFalse(model.consented)
        model.send();await model.work.finish()
        XCTAssertTrue(model.consented);XCTAssertEqual(calls.count,1);XCTAssertEqual(model.report?.summary,"Fixture")
    }
    func testStopDrainsPhysicalMeasurementAndNeverAutoSendsItsLateSnapshot() async {
        let defaults=defaults(),calls=Calls(),entered=expectation(description:"measure"),release=DispatchSemaphore(value:0)
        defaults.set(true,forKey:"localAI.checkupConsented");defer{release.signal()}
        let model=CheckupModel(defaults:defaults,measure:{_,_ in entered.fulfill();_ = release.wait(timeout:.now()+5);return .init(model:"Late")},backend:{calls.hit();return Self.backend},asker:{_,_ in calls.hit();return Self.report()})
        model.start(reading:nil);await fulfillment(of:[entered],timeout:2)
        model.stopFeature()
        var finished=false;let finish=Task {await model.finishFeatureStop();finished=true}
        await Task.yield();XCTAssertFalse(finished)
        release.signal();await finish.value
        XCTAssertEqual(calls.count,0);XCTAssertNil(model.snapshot);XCTAssertNil(model.report)
        XCTAssertTrue(defaults.bool(forKey:"localAI.checkupConsented"),"turning a feature off must not rewrite stored consent")
    }
    func testConfirmedAIRequestRefusesDisableAndQuitUntilItReturns() async throws {
        let defaults=defaults(),entered=expectation(description:"fake AI"),release=DispatchSemaphore(value:0)
        defaults.set(true,forKey:"localAI.checkupConsented");defer{release.signal()}
        let model=CheckupModel(defaults:defaults,measure:{_,_ in .init()},backend:{Self.backend},asker:{_,_ in
            entered.fulfill();await Task.detached{_ = release.wait(timeout:.now()+5)}.value;return Self.report()
        })
        let models=AppModels(defaults:defaults,makeCheckup:{gate in model.work.enabled=gate;return model})
        _=models.checkup;model.start(reading:nil)
        await fulfillment(of:[entered],timeout:2)
        XCTAssertEqual(models.checkupExitBlocker(),.checkup)
        XCTAssertThrowsError(try CheckupModule.prepareStop(models:models));XCTAssertFalse(model.work.stopping)
        release.signal();await model.work.finish()
        XCTAssertEqual(model.report?.summary,"Fixture")
        if let finish=try CheckupModule.prepareStop(models:models){await finish()}
        XCTAssertFalse(models.checkupLoaded);XCTAssertNil(model.report)
    }
    func testOffNavigationStaysColdAndReenableCannotReviveRetiredModel() async throws {
        let defaults=defaults();var creations=0
        let models=AppModels(defaults:defaults,makeCheckup:{gate in creations += 1;return CheckupModel(enabled:gate,defaults:defaults,measure:{_,_ in .init()})})
        let center=ModuleCenter(defaults:defaults,prepareBuiltinStop:{_ in try CheckupModule.prepareStop(models:models)})
        center.setEnabled(CheckupModule.manifest.id,false)
        XCTAssertFalse(center.shows(.checkup));XCTAssertFalse(models.checkupLoaded);XCTAssertEqual(creations,0)
        defaults.set(true,forKey:ModulePreferences.key(CheckupModule.manifest.id))
        let old=models.checkup;old.start(reading:nil);await old.work.finish()
        XCTAssertEqual(old.phase,.preview)
        if let finish=try CheckupModule.prepareStop(models:models){await finish()}
        old.start(reading:nil);XCTAssertEqual(old.work.count,0)
        let fresh=models.checkup;XCTAssertFalse(old === fresh);XCTAssertEqual(creations,2)
        XCTAssertNil(old.snapshot);XCTAssertFalse(defaults.bool(forKey:"localAI.checkupConsented"))
        if let finish=try CheckupModule.prepareStop(models:models){await finish()}
    }
}
