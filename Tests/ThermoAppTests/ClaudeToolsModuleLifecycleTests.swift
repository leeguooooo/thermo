import ModuleKit
import XCTest
@testable import ThermoApp

@MainActor final class ClaudeHostRouteTests:XCTestCase {
    func testRegistryOwnsAccountsResetPrivacyAndGenericEntries() {
        XCTAssertTrue(NativeModules.problems.isEmpty)
        for entry in ["accounts","reset","privacy"] {
            let target=MainPage.native(.init(BuiltinModuleManifests.claude.id,entry))
            XCTAssertEqual(MainPage(argument:"claude:"+entry),target)
            XCTAssertEqual(NativeModules.page(target)?.target,target)
        }
    }
    func testDisabledClaudeRoutesDoNotCreateModels() {
        let name="thermo-claude-target-"+UUID().uuidString,defaults=UserDefaults(suiteName:name)!
        defer{defaults.removePersistentDomain(forName:name)}
        defaults.set(false,forKey:ModulePreferences.key(BuiltinModuleManifests.claude.id))
        let models=AppModels(defaults:defaults)
        for entry in ["accounts","reset","privacy"] {XCTAssertNil(models.nativeFeatures.page(.init(BuiltinModuleManifests.claude.id,entry)))}
        XCTAssertFalse(models.nativeFeatures.status(BuiltinModuleManifests.claude.id).modelLoaded)
    }
}
