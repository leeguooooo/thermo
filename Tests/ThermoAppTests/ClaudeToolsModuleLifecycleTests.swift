import ModuleKit
import XCTest
@testable import ThermoApp

@MainActor final class ClaudeHostRouteTests:XCTestCase {
    func testRegistryOwnsAccountsResetPrivacyAndGenericEntries() {
        XCTAssertTrue(BuiltinModules.problems.isEmpty)
        for entry in ["accounts","reset","privacy"] {
            let target=MainPage.module(ClaudeToolsModule.manifest.id,entry)
            XCTAssertEqual(MainPage(argument:"claude:"+entry),target)
            XCTAssertEqual(BuiltinModules.page(target)?.target,target)
        }
    }
    func testDisabledClaudeRoutesDoNotCreateModels() {
        let name="thermo-claude-target-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:ModulePreferences.key(ClaudeToolsModule.manifest.id))
        let models=AppModels(defaults:defaults)
        for entry in ["accounts","reset","privacy"] {XCTAssertNil(models.nativeFeatures.page(.init(ClaudeToolsModule.manifest.id,entry)))}
        XCTAssertFalse(models.nativeFeatures.status(ClaudeToolsModule.manifest.id).modelLoaded)
    }
}
