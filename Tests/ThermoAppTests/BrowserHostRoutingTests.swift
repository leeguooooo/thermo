import XCTest
import ModuleKit
import NativeFeatureAPI
@testable import ThermoApp

final class BrowserHostRoutingTests:XCTestCase {
    func testAliasesKeepExactBrowserSubjectAndDefault() {
        XCTAssertTrue(BuiltinModules.problems.isEmpty,BuiltinModules.problems.joined(separator:"\n"))
        for app in ["Google Chrome","Arc","Microsoft Edge","Browser: Personal"] {
            let page=MainPage.browser(app)
            XCTAssertEqual(MainPage(argument:"pages:"+app),page)
            XCTAssertEqual(page.module,BuiltinModuleManifests.browser.id)
            XCTAssertEqual(BuiltinModules.page(page)?.entry.scene,"pages")
        }
        XCTAssertEqual(MainPage(argument:"pages:"),MainPage.browser("Google Chrome"))
        XCTAssertEqual(BuiltinModules.page(.module(BrowserModule.manifest.id,""))?.target,.browser("Google Chrome"))
    }
    @MainActor func testOffNavigationAndStatusRemainCold() {
        let name="thermo-browser-host-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:ModulePreferences.key(BrowserModule.manifest.id))
        let models=AppModels(defaults:defaults),center=ModuleCenter(defaults:defaults)
        XCTAssertNil(center.navigationKey(.browser("Arc")));XCTAssertFalse(center.shows(.browser("Arc")))
        XCTAssertNil(models.nativeFeatures.page(.init(BrowserModule.manifest.id,"home")))
        models.nativeFeatures.retireVisibility()
        XCTAssertFalse(models.nativeFeatures.status(BrowserModule.manifest.id).modelLoaded)
        defaults.set(true,forKey:ModulePreferences.key(BrowserModule.manifest.id))
        XCTAssertEqual(center.navigationKey(.browser("Arc")),"4")
    }
}
