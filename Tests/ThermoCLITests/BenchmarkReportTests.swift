import XCTest
@testable import thermo

final class BenchmarkReportTests: XCTestCase {
    private var report: BenchmarkReport {
        BenchmarkReport(model: "Fixture, model", smcKeys: 100, smcSensors: 12, fans: 1,
            measurements: [.init(name: "sample (known)", samples: 100, wallMs: 3.5, cpuMs: 0.25, returnedRecords: 20)],
            estimates: [.init(name: "essential sampling", intervalSeconds: 2, cpuPercent: 0.0125)])
    }

    func testJSONKeepsMeasurementsNumericAndSeparateFromEstimates() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Export.json(report).utf8)) as? [String: Any])
        let rows = try XCTUnwrap(object["measurements"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["wallMs"] as? Double, 3.5)
        XCTAssertEqual(rows[0]["cpuMs"] as? Double, 0.25)
        XCTAssertEqual(rows[0]["samples"] as? Int, 100)
        XCTAssertEqual(rows[0]["returnedRecords"] as? Int, 20)
        XCTAssertNotNil(object["estimates"])
    }

    func testCSVLabelsUnitsAndEscapesModel() {
        let csv = report.csv
        XCTAssertTrue(csv.contains("wall_ms,cpu_ms,returned_records,interval_seconds,cpu_percent"))
        XCTAssertTrue(csv.contains("measurement,sample (known),\"Fixture, model\",100,12,1,100,3.500000,0.250000,20,,"))
        XCTAssertTrue(csv.contains("estimate,essential sampling,\"Fixture, model\",100,12,1,,,,,2,0.012500"))
    }
}
