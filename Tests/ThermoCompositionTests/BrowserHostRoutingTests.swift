import XCTest
import ModuleKit
import NativeFeatureAPI
@testable import ThermoShell
@testable import ThermoComposition

final class BrowserHostRoutingTests:ThermoCompositionTestCase {
    func testAliasesKeepExactBrowserSubjectAndDefault() {
        XCTAssertTrue(NativeModules.problems.isEmpty,NativeModules.problems.joined(separator:"\n"))
        for app in ["Google Chrome","Arc","Microsoft Edge","Browser: Personal"] {
            let page=MainPage.browser(app)
            XCTAssertEqual(MainPage(argument:"pages:"+app),page)
            XCTAssertEqual(page.module,BuiltinModuleManifests.browser.id)
            XCTAssertEqual(NativeModules.page(page)?.entry.scene,"pages")
        }
        XCTAssertEqual(MainPage(argument:"pages:"),MainPage.browser("Google Chrome"))
        XCTAssertEqual(NativeModules.page(.module(BuiltinModuleManifests.browser.id,""))?.target,.browser("Google Chrome"))
    }
    @MainActor func testOffNavigationAndStatusRemainCold() {
        let name="thermo-browser-host-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:ModulePreferences.key(BuiltinModuleManifests.browser.id))
        let models=ShellState(defaults:defaults),center=ModuleCenter(defaults:defaults)
        XCTAssertNil(center.navigationKey(.browser("Arc")));XCTAssertFalse(center.shows(.browser("Arc")))
        XCTAssertNil(models.nativeFeatures.page(.init(BuiltinModuleManifests.browser.id,"home")))
        models.nativeFeatures.retireVisibility()
        XCTAssertFalse(models.nativeFeatures.status(BuiltinModuleManifests.browser.id).modelLoaded)
        defaults.set(true,forKey:ModulePreferences.key(BuiltinModuleManifests.browser.id))
        XCTAssertEqual(center.navigationKey(.browser("Arc")),"4")
    }
}
