import XCTest
import ThermoKit
@testable import thermo

final class MenuBarSettingsTests: XCTestCase {
    private func setting(_ key: String) -> SettingsCommand.Setting { SettingsCommand.all.first { $0.key == key }! }

    func testLegacyMenubarSpellingsRemainAccepted() {
        let s = setting("menubar")
        for (input, stored) in ["cpu": "cpu", "hottest": "hottest", "fan": "fan", "cpu+fan": "cpuAndFan", "power": "power", "icon": "iconOnly"] {
            XCTAssertEqual(s.parse(input) as? String, stored)
            XCTAssertEqual(s.show(stored), input)
        }
        XCTAssertNil(s.parse("cpuUsage"))
    }

    func testNewCLIChoicesAreCanonicalAndInvalidValuesRejected() {
        for key in ["menubar-primary", "menubar-secondary"] {
            let s = setting(key)
            for metric in MenuMetric.allCases {
                XCTAssertEqual(s.parse(metric.rawValue.uppercased()) as? String, metric.rawValue)
            }
            XCTAssertNil(s.parse("cpu+fan")); XCTAssertNil(s.parse("bogus"))
        }
        XCTAssertNil(setting("menubar-primary").parse("none"))
        XCTAssertEqual(setting("menubar-secondary").parse("NONE") as? String, "none")
        for (key, values) in ["menubar-presentation": ["both", "icon", "data"], "menubar-layout": ["horizontal", "stacked"],
                              "menubar-left-click": ["panel", "console"], "menubar-right-click": ["panel", "console"]] {
            for value in values { XCTAssertEqual(setting(key).parse(value.uppercased()) as? String, value) }
            XCTAssertNil(setting(key).parse("invalid"))
        }
    }

    func testNewAndRepeatedLegacyWritesApplyToSamePreferences() {
        let name = "thermo-cli-menu-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        func write(_ key: String, _ value: String) {
            let s = setting(key)
            SettingsCommand.apply(s, value: s.parse(value)!, to: d)
        }
        write("menubar", "cpu+fan")
        XCTAssertEqual(MenuBarPreferences.read(d).metrics, [.cpu, .fan])
        write("menubar-primary", "memory"); write("menubar-secondary", "upload")
        write("menubar-presentation", "data")
        XCTAssertEqual(MenuBarPreferences.read(d).metrics, [.memory, .upload])
        write("menubar", "cpu+fan")
        XCTAssertEqual(MenuBarPreferences.read(d).metrics, [.cpu, .fan])
        XCTAssertEqual(MenuBarPreferences.read(d).presentation, .both)
        write("menubar", "icon")
        XCTAssertTrue(MenuBarPreferences.read(d).metrics.isEmpty)
    }
}
