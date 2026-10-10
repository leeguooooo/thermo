import XCTest
@testable import thermo

final class PulseCSVTests: XCTestCase {
    func testPulseCSVKeepsUnitsAndNestedProgramDetails() {
        struct Program: Encodable {
            let name = "Fixture, app"
            let memoryKB = 1024
            let args = ["--token", "synthetic secret value"]
        }
        struct Report: Encodable {
            let load1 = 1.5
            let swapUsedMB = 2048
            let temperatures = ["cpu": 65.5]
            let programs = [Program()]
        }
        let csv = Export.pulseCSV(Report())
        XCTAssertTrue(csv.hasPrefix("kind,name,value,unit\n"))
        XCTAssertTrue(csv.contains("system,load1,1.5,load"))
        XCTAssertTrue(csv.contains("system,swapUsedMB,2048,MiB"))
        XCTAssertTrue(csv.contains("temperature,cpu,65.5,°C"))
        XCTAssertTrue(csv.contains("program,\"Fixture, app\""))
        XCTAssertTrue(csv.contains("memoryKB"))
        XCTAssertFalse(csv.contains("synthetic secret value"))
    }
}
