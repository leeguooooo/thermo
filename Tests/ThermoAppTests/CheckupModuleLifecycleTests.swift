import ModuleKit
import XCTest
@testable import ThermoApp

@MainActor final class CheckupHostRouteTests:XCTestCase {
    func testRegistryOwnsLegacyAndGenericCheckupPages() {
        XCTAssertTrue(NativeModules.problems.isEmpty,NativeModules.problems.joined(separator:"\n"))
        XCTAssertEqual(MainPage(argument:"checkup")?.module,BuiltinModuleManifests.checkup.id)
        XCTAssertEqual(NativeModules.page(MainPage(argument:"checkup")!)?.target,.native(.init(BuiltinModuleManifests.checkup.id,"home")))
        XCTAssertEqual(NativeModules.page(.native(.init(BuiltinModuleManifests.checkup.id,"home")))?.target,.native(.init(BuiltinModuleManifests.checkup.id,"home")))
    }
}
