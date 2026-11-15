import ModuleKit
import XCTest
@testable import ThermoApp

final class DownloadModuleHostTests: XCTestCase {
    func testRegistryPreservesLegacyAndGenericDownloadPages() {
        XCTAssertTrue(NativeModules.problems.isEmpty)
        let route=MainPage.native(.init(BuiltinModuleManifests.download.id,"home"))
        for argument in ["yunx","yunx:","yunx:legacy"] {XCTAssertEqual(MainPage(argument:argument),route)}
        XCTAssertEqual(route.module,BuiltinModuleManifests.download.id)
        XCTAssertEqual(NativeModules.page(route)?.target,route)
    }
}
