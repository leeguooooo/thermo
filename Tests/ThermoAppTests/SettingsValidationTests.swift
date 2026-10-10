import XCTest
import ThermoL10n
@testable import ThermoApp

final class SettingsValidationTests: XCTestCase {
    func testInvalidIntervalsCannotReachTimerConversions() {
        for value in [Double.nan, .infinity, -.infinity, -1, 0, 3, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(Settings.intervalValue(value), 2)
        }
        for value in [0.5, 1, 2, 5] { XCTAssertEqual(Settings.intervalValue(value), value) }
    }

    func testFractionalThresholdIsDisplayedWithoutTruncation() {
        XCTAssertEqual(Settings.thresholdText(91.5, fahrenheit: false), "91.5")
        XCTAssertEqual(Settings.thresholdText(91.5, fahrenheit: true), "196.7")
        XCTAssertEqual(Settings.thresholdText(.nan, fahrenheit: false), "90")
        XCTAssertEqual(Settings.thresholdValue(105), 105)
        XCTAssertEqual(Settings.thresholdValue(106), 90)
    }

    func testNormalizationRepairsInvalidValuesButKeepsValidPreferences() throws {
        let name = "thermo-settings-fixture-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Double.infinity, forKey: Settings.interval)
        defaults.set(91.5, forKey: Settings.alertThreshold)
        defaults.set("unknown", forKey: Settings.titleMetric)
        defaults.set("unsupported", forKey: L10n.defaultsKey)
        defaults.set(true, forKey: Settings.alertsEnabled)
        Settings.register(defaults)
        XCTAssertEqual(defaults.double(forKey: Settings.interval), 2)
        XCTAssertEqual(defaults.double(forKey: Settings.alertThreshold), 91.5)
        XCTAssertEqual(defaults.string(forKey: Settings.titleMetric), "cpu")
        XCTAssertEqual(defaults.string(forKey: L10n.defaultsKey), "system")
        XCTAssertTrue(defaults.bool(forKey: Settings.alertsEnabled))
        defaults.set(0.5, forKey: Settings.interval)
        defaults.set("power", forKey: Settings.titleMetric)
        defaults.set("en", forKey: L10n.defaultsKey)
        Settings.normalize(defaults)
        XCTAssertEqual(defaults.double(forKey: Settings.interval), 0.5)
        XCTAssertEqual(defaults.string(forKey: Settings.titleMetric), "power")
        XCTAssertEqual(defaults.string(forKey: L10n.defaultsKey), "en")
    }
}
