import ModuleKit
import NativeFeatureAPI
import XCTest
@testable import ThermoShell
@testable import ThermoComposition

@MainActor final class ConnectionsHostRouteTests:ThermoCompositionTestCase {
    func testRegistryOwnsLegacyAndGenericConnectionPage() {
        XCTAssertTrue(NativeModules.problems.isEmpty,NativeModules.problems.joined(separator:"\n"))
        XCTAssertEqual(MainPage(argument:"connections")?.module,BuiltinModuleManifests.connections.id)
        XCTAssertEqual(NativeModules.page(MainPage(argument:"connections")!)?.target,.native(.init(BuiltinModuleManifests.connections.id,"home")))
        XCTAssertEqual(NativeModules.page(.native(.init(BuiltinModuleManifests.connections.id,"home")))?.target,.native(.init(BuiltinModuleManifests.connections.id,"home")))
    }

    func testDisabledRouteAndNativeStatusStayCold() {
        let name="thermo-connections-host-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:ModulePreferences.key(BuiltinModuleManifests.connections.id))
        let models=ShellState(defaults:defaults),center=ModuleCenter(defaults:defaults)
        XCTAssertFalse(center.shows(.native(.init(BuiltinModuleManifests.connections.id,"home"))))
        XCTAssertNil(models.nativeFeatures.page(.init(BuiltinModuleManifests.connections.id,"home")))
        XCTAssertFalse(models.nativeFeatures.status(BuiltinModuleManifests.connections.id).modelLoaded)
        models.nativeFeatures.retireVisibility();XCTAssertNil(models.nativeFeatures.quitBlocker())
    }
}
