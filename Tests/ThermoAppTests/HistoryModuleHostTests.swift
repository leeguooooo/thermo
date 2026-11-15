import ModuleKit
import XCTest
@testable import ThermoApp

@MainActor final class HistoryModuleHostTests: XCTestCase {
    func testRegistryOwnsLegacyAndGenericHistoryPage() {
        XCTAssertTrue(BuiltinModules.problems.isEmpty,BuiltinModules.problems.joined(separator:"\n"))
        XCTAssertEqual(MainPage.module(HistoryModule.manifest.id,"home").module,HistoryModule.manifest.id)
        XCTAssertEqual(MainPage(argument:"history"),.module(HistoryModule.manifest.id,"home"))
        XCTAssertEqual(BuiltinModules.page(.module(HistoryModule.manifest.id,"home"))?.target,.module(HistoryModule.manifest.id,"home"))
    }
}
