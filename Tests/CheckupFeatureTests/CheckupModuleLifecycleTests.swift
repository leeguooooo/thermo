import ModuleKit
import NativeFeatureAPI
import LocalAIUI
import XCTest
@testable import CleanKit
@testable import CheckupFeature

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
        let manifest=BuiltinModuleManifests.checkup
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in
            CheckupSession(availability:availability,reading:{nil},navigate:{_ in XCTFail("unexpected navigation")},makeModel:{gate in model.work.enabled=gate;return model})
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true})
        _=store.page(.init(manifest.id,"home"));model.start(reading:nil)
        await fulfillment(of:[entered],timeout:2)
        XCTAssertEqual(store.quitBlocker()?.route,NativeFeatureRoute(manifest.id,"home"))
        XCTAssertThrowsError(try store.prepareStop(manifest.id));XCTAssertFalse(model.work.stopping)
        release.signal();await model.work.finish()
        XCTAssertEqual(model.report?.summary,"Fixture")
        if let drain=try store.prepareStop(manifest.id){await drain.finish()}
        XCTAssertFalse(store.status(manifest.id).modelLoaded);XCTAssertNil(model.report)
    }
    func testOffNavigationStaysColdAndReenableCannotReviveRetiredModel() async throws {
        let defaults=defaults();var enabled=false,models:[CheckupModel]=[]
        let manifest=BuiltinModuleManifests.checkup
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in
            CheckupSession(availability:availability,reading:{nil},navigate:{_ in XCTFail("unexpected navigation")},makeModel:{gate in
                let model=CheckupModel(enabled:gate,defaults:defaults,measure:{_,_ in .init()});models.append(model);return model
            })
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in enabled}),route=NativeFeatureRoute(manifest.id,"home")
        XCTAssertNil(store.page(route));XCTAssertFalse(store.status(manifest.id).modelLoaded);XCTAssertTrue(models.isEmpty)
        enabled=true;XCTAssertNotNil(store.page(route));let old=try XCTUnwrap(models.first)
        old.start(reading:nil);await old.work.finish();XCTAssertEqual(old.phase,.preview)
        if let drain=try store.prepareStop(manifest.id){await drain.finish()}
        old.start(reading:nil);XCTAssertEqual(old.work.count,0)
        XCTAssertNotNil(store.page(route));let fresh=try XCTUnwrap(models.last)
        XCTAssertFalse(old === fresh);XCTAssertEqual(models.count,2);XCTAssertNil(old.snapshot)
        XCTAssertFalse(defaults.bool(forKey:"localAI.checkupConsented"))
        if let drain=try store.prepareStop(manifest.id){await drain.finish()}
    }
    func testSharedConsentDoesNotRequireAnotherFeaturesModel() {
        let defaults=defaults(),a=CheckupConsent(defaults:defaults),b=CheckupConsent(defaults:defaults)
        XCTAssertFalse(a.allowed);a.allowed=true;XCTAssertTrue(b.allowed)
        XCTAssertTrue(defaults.bool(forKey:"localAI.checkupConsented"))
    }
    func testOffReviewCannotReadFixtureOrCreateModel() {
        let calls=Calls(),manifest=BuiltinModuleManifests.checkup
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in calls.hit();return CheckupSession(availability:availability,reading:{calls.hit();return nil},navigate:{_ in})})
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in false})
        store.prepareReview(.init(manifest.id,"home"),arguments:["--fixture","/must-not-read"])
        XCTAssertEqual(calls.count,0);XCTAssertFalse(store.status(manifest.id).modelLoaded)
    }
    func testFixtureLoadsWithoutReadingSensorsOrSendingAI() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-checkup-target-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let answer=root.appendingPathComponent("answer.json")
        try Data(#"{"overall":"good","summary":"Owned fixture","findings":[]}"#.utf8).write(to:answer)
        let calls=Calls(),model=CheckupModel(defaults:defaults(),measure:{_,_ in calls.hit();return .init()},backend:{calls.hit();return Self.backend},asker:{_,_ in calls.hit();return Self.report()})
        let manifest=BuiltinModuleManifests.checkup
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{availability in
            CheckupSession(availability:availability,reading:{calls.hit();return nil},navigate:{_ in},makeModel:{gate in model.work.enabled=gate;return model})
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true})
        store.prepareReview(.init(manifest.id,"home"),arguments:["--fixture",answer.path])
        XCTAssertEqual(model.report?.source,"fixture");XCTAssertEqual(calls.count,0)
        if let drain=try store.prepareStop(manifest.id){await drain.finish()}
    }
}
