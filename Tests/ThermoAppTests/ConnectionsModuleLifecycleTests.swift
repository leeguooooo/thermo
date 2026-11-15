import ModuleKit
import NativeFeatureAPI
import XCTest
@testable import ThermoApp

@MainActor final class ConnectionsHostRouteTests:XCTestCase {
    func testRegistryOwnsLegacyAndGenericConnectionPage() {
        XCTAssertTrue(BuiltinModules.problems.isEmpty,BuiltinModules.problems.joined(separator:"\n"))
        XCTAssertEqual(MainPage(argument:"connections")?.module,ConnectionsModule.manifest.id)
        XCTAssertEqual(BuiltinModules.page(MainPage(argument:"connections")!)?.target,.module(ConnectionsModule.manifest.id,"home"))
        XCTAssertEqual(BuiltinModules.page(.module(ConnectionsModule.manifest.id,"home"))?.target,.module(ConnectionsModule.manifest.id,"home"))
    }

    func testDisabledRouteAndNativeStatusStayCold() {
        let name="thermo-connections-host-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:ModulePreferences.key(ConnectionsModule.manifest.id))
        let models=AppModels(defaults:defaults),center=ModuleCenter(defaults:defaults)
        XCTAssertFalse(center.shows(.module(ConnectionsModule.manifest.id,"home")))
        XCTAssertNil(models.nativeFeatures.page(.init(ConnectionsModule.manifest.id,"home")))
        XCTAssertFalse(models.nativeFeatures.status(ConnectionsModule.manifest.id).modelLoaded)
        models.nativeFeatures.retireVisibility();XCTAssertNil(models.nativeFeatures.quitBlocker())
    }
}
