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
}
