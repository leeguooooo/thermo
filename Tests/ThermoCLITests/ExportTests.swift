import XCTest
import ThermoKit
@testable import thermo

final class ExportTests: XCTestCase {
    func testStreamingHighestTemperatureIncludesStorage() {
        let sample = Snapshot(temperatures: [
            Reading(key: "cpu", name: "CPU", group: .cpu, value: 70),
            Reading(key: "storage", name: "Storage", group: .storage, value: 95),
        ], fans: [], power: [], voltages: [], currents: [], battery: nil)
        let fields = Export.csvStreamRow(sample).split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(fields[1], "70.00")
        XCTAssertEqual(fields[3], "95.00")
    }
    func testCSVQuotesNewlinesCarriageReturnsAndQuotes() {
        XCTAssertEqual(Export.csvField("two\nlines"), "\"two\nlines\"")
        XCTAssertEqual(Export.csvField("two\rlines"), "\"two\rlines\"")
        XCTAssertEqual(Export.csvField("a,\"b\""), "\"a,\"\"b\"\"\"")
        XCTAssertEqual(Export.csvField("plain"), "plain")
    }

    func testBatteryExportIncludesUnitsSignedPowerAndZeroStates() throws {
        let battery = try JSONDecoder().decode(BatteryInfo.self, from: Data("""
        {"percent":0,"temperature":31.5,"voltage":12,"amperage":-1.5,
         "cycleCount":42,"health":0.84,"charging":false,"externalPower":false}
        """.utf8))
        let csv = Export.csv(battery)
        XCTAssertTrue(csv.hasPrefix("kind,key,name,group,value\n"))
        XCTAssertTrue(csv.contains("battery,charge_percent,Charge (%),Battery,0.000"))
        XCTAssertTrue(csv.contains("battery,power_w,Power (W),Battery,-18.000"))
        XCTAssertTrue(csv.contains("battery,health_percent,Health (%),Battery,84.000"))
        XCTAssertTrue(csv.contains("battery,charging,Charging (0/1),Battery,0.000"))
        let snapshot = Snapshot(temperatures: [], fans: [], power: [], voltages: [], currents: [], battery: battery)
        XCTAssertEqual(Export.csv(snapshot, all: false), csv)
    }

    func testMissingBatteryMeasurementsAreOmitted() throws {
        let battery = try JSONDecoder().decode(BatteryInfo.self, from: Data("""
        {"charging":false,"externalPower":true}
        """.utf8))
        XCTAssertEqual(Export.batteryRows(battery).count, 2)
        XCTAssertFalse(Export.csv(battery).contains("temperature_c"))
    }
}
