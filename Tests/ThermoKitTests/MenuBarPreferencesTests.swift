import XCTest
@testable import ThermoKit

final class MenuBarPreferencesTests: XCTestCase {
    private func fixture(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "thermo-menu-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        try body(d)
    }

    func testAllLegacyChoicesMigrateAndRemainStable() {
        fixture { d in
            for value in ["cpu", "hottest", "fan", "cpuAndFan", "power", "iconOnly"] {
                d.set(value, forKey: "titleMetric")
                MenuBarPreferences.normalize(d)
                XCTAssertEqual(MenuBarPreferences.read(d), MenuBarPreferences.legacy(value), value)
                MenuBarPreferences.normalize(d)
                XCTAssertEqual(MenuBarPreferences.read(d), MenuBarPreferences.legacy(value), value)
            }
        }
    }

    func testIndependentSelectionsAndActionsSurviveNormalization() {
        fixture { d in
            MenuBarPreferences.normalize(d)
            d.set("upload", forKey: MenuBarPreferences.primaryKey)
            d.set("hottest", forKey: MenuBarPreferences.secondaryKey)
            d.set("data", forKey: MenuBarPreferences.presentationKey)
            d.set("stacked", forKey: MenuBarPreferences.layoutKey)
            d.set("console", forKey: MenuBarPreferences.rightKey)
            MenuBarPreferences.normalize(d)
            let p = MenuBarPreferences.read(d)
            XCTAssertEqual(p.metrics, [.upload, .hottest])
            XCTAssertEqual(p.layout, .stacked)
            XCTAssertEqual(p.presentation, .data)
            XCTAssertEqual(p.left, .panel)
            XCTAssertEqual(p.right, .console)
        }
    }

    func testInvalidPreferencesRepairWithoutCrossMetricFallback() {
        fixture { d in
            MenuBarPreferences.normalize(d)
            for key in [MenuBarPreferences.primaryKey, MenuBarPreferences.secondaryKey, MenuBarPreferences.presentationKey,
                        MenuBarPreferences.layoutKey, MenuBarPreferences.leftKey, MenuBarPreferences.rightKey] {
                d.set("invalid", forKey: key)
            }
            MenuBarPreferences.normalize(d)
            XCTAssertEqual(MenuBarPreferences.read(d), MenuBarPreferences())
            XCTAssertEqual(d.string(forKey: MenuBarPreferences.secondaryKey), "none")
        }
    }

    func testRepeatedLegacyWriteOverridesNewSelections() {
        fixture { d in
            MenuBarPreferences.normalize(d)
            d.set("memory", forKey: MenuBarPreferences.primaryKey)
            MenuBarPreferences.applyLegacy("cpu", to: d)
            MenuBarPreferences.normalize(d)
            XCTAssertEqual(MenuBarPreferences.read(d).primary, .cpu)
        }
    }

    func testIconOnlyNeedsNoMetricResourcesButKeepsSelections() {
        var p = MenuBarPreferences()
        p.primary = .cpuUsage; p.secondary = .download; p.presentation = .icon
        XCTAssertTrue(p.metrics.isEmpty)
        p.presentation = .data
        XCTAssertEqual(p.metrics, [.cpuUsage, .download])
        p.secondary = nil
        XCTAssertEqual(p.metrics, [.cpuUsage])
    }
}
