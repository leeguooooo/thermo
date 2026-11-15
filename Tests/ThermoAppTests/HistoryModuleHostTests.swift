import ModuleKit
import XCTest
@testable import ThermoApp

@MainActor final class HistoryModuleHostTests: XCTestCase {
    func testRegistryOwnsLegacyAndGenericHistoryPage() {
        XCTAssertTrue(NativeModules.problems.isEmpty,NativeModules.problems.joined(separator:"\n"))
        XCTAssertEqual(MainPage.native(.init(BuiltinModuleManifests.history.id,"home")).module,BuiltinModuleManifests.history.id)
        for argument in ["history", "history:", "history:legacy"] {
            XCTAssertEqual(MainPage(argument:argument),.native(.init(BuiltinModuleManifests.history.id,"home")))
        }
        XCTAssertEqual(NativeModules.page(.native(.init(BuiltinModuleManifests.history.id,"home")))?.target,.native(.init(BuiltinModuleManifests.history.id,"home")))
    }
}
