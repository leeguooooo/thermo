import ModuleKit
import XCTest
@testable import ThermoApp

final class DownloadModuleHostTests: XCTestCase {
    func testRegistryPreservesLegacyAndGenericDownloadPages() {
        XCTAssertTrue(BuiltinModules.problems.isEmpty)
        let route=MainPage.module(DownloadModule.manifest.id,"home")
        for argument in ["yunx","yunx:","yunx:legacy"] {XCTAssertEqual(MainPage(argument:argument),route)}
        XCTAssertEqual(route.module,DownloadModule.manifest.id)
        XCTAssertEqual(BuiltinModules.page(route)?.target,route)
    }
}
