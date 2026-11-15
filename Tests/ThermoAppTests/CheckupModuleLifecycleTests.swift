import ModuleKit
import XCTest
@testable import ThermoApp

@MainActor final class CheckupHostRouteTests:XCTestCase {
    func testRegistryOwnsLegacyAndGenericCheckupPages() {
        XCTAssertTrue(BuiltinModules.problems.isEmpty,BuiltinModules.problems.joined(separator:"\n"))
        XCTAssertEqual(MainPage(argument:"checkup")?.module,CheckupModule.manifest.id)
        XCTAssertEqual(BuiltinModules.page(MainPage(argument:"checkup")!)?.target,.module(CheckupModule.manifest.id,"home"))
        XCTAssertEqual(BuiltinModules.page(.module(CheckupModule.manifest.id,"home"))?.target,.module(CheckupModule.manifest.id,"home"))
    }
}
