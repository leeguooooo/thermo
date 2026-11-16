import ModuleKit
import NativeFeatureAPI
import XCTest
@testable import ThermoShell
@testable import ThermoComposition

@MainActor final class FeatureCenterRoutingTests:ThermoCompositionTestCase {
    func testFeatureCenterIsAvailableWhenEveryOptionalFeatureIsOff() {
        let name="thermo-feature-center-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        for manifest in ShellNativeCatalog.catalog.manifests{defaults.set(false,forKey:ModulePreferences.key(manifest.id))}
        let center=ModuleCenter(defaults:defaults)
        XCTAssertEqual(MainPage(argument:"features"),.features)
        XCTAssertNil(MainPage.features.nativeRoute);XCTAssertNil(MainPage.features.module)
        XCTAssertTrue(center.shows(.features));XCTAssertTrue(center.switches.allSatisfy{!$0.enabled})
        XCTAssertTrue(HostPageSpecification.pages.contains{$0.argument=="features" && $0.key.isEmpty})
    }
    func testStopReportWaitsForTheDrainInsteadOfOnlyTheDisabledPreference()async throws {
        let name="thermo-feature-stop-report-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        let id=BuiltinModuleManifests.performance.id
        defaults.set(true,forKey:ModulePreferences.key(id));defaults.set("kept",forKey:"saved-record-fixture")
        let entered=expectation(description:"drain still owns its work")
        var completion:CheckedContinuation<Void,Never>?
        let center=ModuleCenter(defaults:defaults,prepareBuiltinStop:{_ in
            {await withCheckedContinuation{completion=$0;entered.fulfill()}}
        })
        center.setEnabled(id,false)
        await fulfillment(of:[entered],timeout:2)
        XCTAssertFalse(center.isOn(id));XCTAssertTrue(center.changing.contains(id));XCTAssertEqual(center.stopProgress[id],.waiting)
        center.setEnabled(id,true);XCTAssertFalse(center.isOn(id))
        try XCTUnwrap(completion).resume()
        for _ in 0..<100 where center.changing.contains(id){try await Task.sleep(nanoseconds:10_000_000)}
        XCTAssertEqual(center.stopProgress[id],.nativeFinished);XCTAssertFalse(center.changing.contains(id))
        XCTAssertEqual(defaults.string(forKey:"saved-record-fixture"),"kept")
        center.setEnabled(id,true);XCTAssertNil(center.stopProgress[id]);XCTAssertTrue(center.isOn(id))
    }
    func testRefusalReportsTheReasonAndKeepsTheFeatureEnabled() {
        let name="thermo-feature-refused-report-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        let id=BuiltinModuleManifests.performance.id;defaults.set(true,forKey:ModulePreferences.key(id))
        let center=ModuleCenter(defaults:defaults,prepareBuiltinStop:{_ in throw NativeModules.StopRefused(description:"fixture is busy")})
        center.setEnabled(id,false)
        XCTAssertTrue(center.isOn(id));XCTAssertEqual(center.stopProgress[id],.refused("fixture is busy"));XCTAssertTrue(center.changing.isEmpty)
    }
}
