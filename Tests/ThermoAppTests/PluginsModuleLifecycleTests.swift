import ModuleKit
import NativeFeatureAPI
import XCTest
@testable import ThermoApp

@MainActor final class PluginsHostRouteTests:XCTestCase {
    func testRegistryOwnsBothPageForms() {
        XCTAssertTrue(BuiltinModules.problems.isEmpty)
        XCTAssertEqual(MainPage(argument:"plugins")?.module,PluginsModule.manifest.id)
        XCTAssertEqual(BuiltinModules.page(.module(PluginsModule.manifest.id,"home"))?.target,.module(PluginsModule.manifest.id,"home"))
    }

    func testDisabledPluginRouteDoesNotCreateModel() {
        let name="thermo-plugin-host-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:ModulePreferences.key(PluginsModule.manifest.id))
        let models=AppModels(defaults:defaults)
        XCTAssertNil(models.nativeFeatures.page(.init(PluginsModule.manifest.id,"home")))
        XCTAssertFalse(models.nativeFeatures.status(PluginsModule.manifest.id).modelLoaded)
    }
}
