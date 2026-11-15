import XCTest
import ThermoKit
@testable import PerformanceFeature

final class SensorSearchTests:XCTestCase {
    func testSensorSearchMatchesKeysAndDisplayedElectricalCategories() {
        let reading = Reading(key: "PC0R", name: "CPU Package Power", group: .cpu, value: 42)
        XCTAssertTrue(SensorSearch.matches(reading, query: " pc0r "))
        XCTAssertTrue(SensorSearch.matches(reading, query: "功率", category: "功率"))
        XCTAssertFalse(SensorSearch.matches(reading, query: "功率"))
        XCTAssertFalse(SensorSearch.matches(reading, query: "not a sensor", category: "功率"))
    }
}
