import ModuleKit
import XCTest
@testable import ThermoApp

final class ClaudeLegacyRouteTests:XCTestCase {
    func testStandaloneNavigation() {
        XCTAssertEqual(MainPage(argument: "claude-cleanup"), .native(.init(BuiltinModuleManifests.claude.id,"reset")))
        XCTAssertEqual(MainPage(argument: "claude-cleanup:privacy"), .native(.init(BuiltinModuleManifests.claude.id,"privacy")))
        XCTAssertEqual(MainPage(argument: "claude"), .native(.init(BuiltinModuleManifests.claude.id,"accounts")))
        XCTAssertEqual(MainPage(argument: "checkup"), .native(.init(BuiltinModuleManifests.checkup.id,"home")))
        XCTAssertEqual(MainPage(argument: "claude:reset"), .native(.init(BuiltinModuleManifests.claude.id,"reset")))
    }
    func testUnknownLegacyTabRetainsItsPreviousFallback() {
        XCTAssertEqual(MainPage(argument:"claude:unknown"),.native(.init(BuiltinModuleManifests.claude.id,"accounts")))
        XCTAssertEqual(MainPage(argument:"claude-cleanup:unknown"),.native(.init(BuiltinModuleManifests.claude.id,"reset")))
    }
}
