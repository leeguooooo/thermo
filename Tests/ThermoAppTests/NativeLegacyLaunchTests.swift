import ModuleKit
import NativeFeatureAPI
import XCTest
@testable import ThermoApp

final class NativeLegacyLaunchTests:XCTestCase {
    func testLegacyLaunchFlagsKeepTheirDeclaredPageAndContext()throws {
        let catalog=BuiltinNativeFeatures.catalog
        XCTAssertNil(try catalog.resolveLegacyLaunch(["--main","--page","settings"]))
        XCTAssertEqual(try catalog.resolveLegacyLaunch(["--disk"])?.route,.init(BuiltinModuleManifests.disk.id,"scan"))
        XCTAssertEqual(try catalog.resolveLegacyLaunch(["--disk","--page","overview"])?.route,.init(BuiltinModuleManifests.disk.id,"overview"))
        XCTAssertEqual(try catalog.resolveLegacyLaunch(["--agents"])?.route,.init(BuiltinModuleManifests.agents.id,"home"))
        XCTAssertEqual(try catalog.resolveLegacyLaunch(["--chrome-pages"])?.route,.init(BuiltinModuleManifests.browser.id,"home",context:["app":.text("Google Chrome")]))
        XCTAssertEqual(try catalog.resolveLegacyLaunch(["--chrome-pages","--app","Browser: Personal"])?.route,.init(BuiltinModuleManifests.browser.id,"home",context:["app":.text("Browser: Personal")]))
        XCTAssertThrowsError(try catalog.resolveLegacyLaunch(["--chrome-pages","--app","bad\nname"]))
        XCTAssertThrowsError(try catalog.resolveLegacyLaunch(["--disk","--agents"]))
    }
    @MainActor func testDisabledLegacyDestinationStaysSelectedWithoutLoadingItsModel()throws {
        let name="thermo-legacy-off-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:ModulePreferences.key(BuiltinModuleManifests.disk.id))
        let models=AppModels(defaults:defaults)
        let page=try NativeModules.prepareReview(["--disk"],page:.settings,models:models)
        XCTAssertEqual(page,.native(.init(BuiltinModuleManifests.disk.id,"scan")))
        XCTAssertFalse(models.nativeFeatures.status(BuiltinModuleManifests.disk.id).modelLoaded)
    }
}
