import ModuleHost
import ModuleKit
import XCTest
@testable import ThermoApp

@MainActor final class ModuleCenterTests: XCTestCase {
    func testPageArgumentNamesAModuleAndOptionallyItsEntry() {
        XCTAssertEqual(MainPage(argument: "module:dev.thermo.disk"), .module("dev.thermo.disk", ""))
        XCTAssertEqual(MainPage(argument: "module:dev.thermo.disk:scan"), .module("dev.thermo.disk", "scan"))
        XCTAssertNil(MainPage(argument: "module"))
    }

    func testAnAppWithoutModulesShowsNoneAndStartsNothing() async {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-none-" + UUID().uuidString + "/Thermo.app")
        let name = "thermo-module-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let center = ModuleCenter(manager: ModuleManager(app: empty), defaults: defaults)
        center.start()
        for _ in 0..<100 where !center.loaded { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(center.loaded)
        XCTAssertTrue(center.statuses.isEmpty && center.pages.isEmpty)
        XCTAssertNil(center.page(module: "dev.thermo.disk", entry: ""))
        // Switching an unknown module only records the choice.
        center.setEnabled("dev.thermo.disk", true)
        XCTAssertEqual(defaults.object(forKey: ModuleCenter.key("dev.thermo.disk")) as? Bool, true)
        XCTAssertTrue(center.pages.isEmpty)
    }
}
