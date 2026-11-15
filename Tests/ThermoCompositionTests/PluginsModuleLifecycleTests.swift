import ModuleKit
import NativeFeatureAPI
import XCTest
@testable import ThermoShell
@testable import ThermoComposition

@MainActor final class PluginsHostRouteTests:ThermoCompositionTestCase {
    func testRegistryOwnsBothPageForms() {
        XCTAssertTrue(NativeModules.problems.isEmpty)
        XCTAssertEqual(MainPage(argument:"plugins")?.module,BuiltinModuleManifests.plugins.id)
        XCTAssertEqual(NativeModules.page(.native(.init(BuiltinModuleManifests.plugins.id,"home")))?.target,.native(.init(BuiltinModuleManifests.plugins.id,"home")))
    }

    func testDisabledPluginRouteDoesNotCreateModel() {
        let name="thermo-plugin-host-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:ModulePreferences.key(BuiltinModuleManifests.plugins.id))
        let models=ShellState(defaults:defaults)
        XCTAssertNil(models.nativeFeatures.page(.init(BuiltinModuleManifests.plugins.id,"home")))
        XCTAssertFalse(models.nativeFeatures.status(BuiltinModuleManifests.plugins.id).modelLoaded)
    }
}
