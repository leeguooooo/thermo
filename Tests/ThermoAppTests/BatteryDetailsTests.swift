import XCTest
import ThermoL10n
@testable import ThermoKit
@testable import ThermoApp

final class BatteryDetailsTests: XCTestCase {
    override func setUp() { L10n.override = .english }
    override func tearDown() { L10n.override = nil }

    func testDetailsIncludeHealthCyclesAndSignedPower() {
        let battery = BatteryInfo(percent: 80, temperature: 30, voltage: 12, amperage: -1,
                                  cycleCount: 100, health: 0.9, charging: false, externalPower: false)
        let details = BatteryDetails(battery: battery, fahrenheit: true)
        let values = Dictionary(uniqueKeysWithValues: details.rows)
        XCTAssertEqual(values["Battery health"], "90%")
        XCTAssertEqual(values["Cycle count"], "100")
        XCTAssertEqual(values["Temperature"], "86°F")
        XCTAssertEqual(values["Power"], "-12.0 W")
        XCTAssertEqual(values["Power source"], "On battery")
    }

    func testSearchIncludesLocalizedBatteryFields() {
        XCTAssertTrue(BatteryDetails.matches(query: " health "))
        L10n.override = .simplifiedChinese
        XCTAssertTrue(BatteryDetails.matches(query: "健康度"))
        XCTAssertTrue(BatteryDetails.matches(query: "电池"))
        XCTAssertFalse(BatteryDetails.matches(query: "no such field"))
    }
}
