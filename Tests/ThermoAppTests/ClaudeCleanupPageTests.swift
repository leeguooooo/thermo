import ModuleKit
import XCTest
@testable import ThermoApp

final class ClaudeLegacyRouteTests:XCTestCase {
    func testStandaloneNavigation() {
        XCTAssertEqual(MainPage(argument: "claude-cleanup"), .module(BuiltinModuleManifests.claude.id,"reset"))
        XCTAssertEqual(MainPage(argument: "claude-cleanup:privacy"), .module(BuiltinModuleManifests.claude.id,"privacy"))
        XCTAssertEqual(MainPage(argument: "claude"), .module(BuiltinModuleManifests.claude.id,"accounts"))
        XCTAssertEqual(MainPage(argument: "checkup"), .module(BuiltinModuleManifests.checkup.id,"home"))
        XCTAssertEqual(MainPage(argument: "claude:reset"), .module(BuiltinModuleManifests.claude.id,"reset"))
    }
    func testUnknownLegacyTabRetainsItsPreviousFallback() {
        XCTAssertEqual(MainPage(argument:"claude:unknown"),.module(BuiltinModuleManifests.claude.id,"accounts"))
        XCTAssertEqual(MainPage(argument:"claude-cleanup:unknown"),.module(BuiltinModuleManifests.claude.id,"reset"))
    }
}
