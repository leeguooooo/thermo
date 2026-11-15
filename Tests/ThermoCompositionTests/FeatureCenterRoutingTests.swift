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
}
