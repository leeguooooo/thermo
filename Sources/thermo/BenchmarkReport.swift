import Foundation
import ThermoKit

struct BenchmarkReport: Encodable {
    struct Measurement: Encodable {
        let name: String
        let samples: Int
        let wallMs: Double
        let cpuMs: Double
        let returnedRecords: Int?
    }
    struct Estimate: Encodable {
        let name: String
        let intervalSeconds: Double
        let cpuPercent: Double
    }
    let model: String
    let smcKeys: UInt32
    let smcSensors: Int
    let fans: Int
    let measurements: [Measurement]
    let estimates: [Estimate]

    static func recordCount(_ snapshot: Snapshot) -> Int {
        snapshot.temperatures.count + snapshot.power.count + snapshot.voltages.count
            + snapshot.currents.count + snapshot.fans.count
    }

    var csv: String {
        let columns = ["kind", "name", "model", "smc_keys", "smc_sensors", "fans", "samples", "wall_ms", "cpu_ms", "returned_records", "interval_seconds", "cpu_percent"]
        func row(_ kind: String, _ name: String, _ values: [String]) -> String {
            ([kind, name, model, String(smcKeys), String(smcSensors), String(fans)] + values)
                .map(Export.csvField).joined(separator: ",")
        }
        var rows = [columns.joined(separator: ",")]
        rows += measurements.map {
            row("measurement", $0.name, [String($0.samples), String(format: "%.6f", $0.wallMs),
                String(format: "%.6f", $0.cpuMs), $0.returnedRecords.map(String.init) ?? "", "", ""])
        }
        rows += estimates.map {
            row("estimate", $0.name, ["", "", "", "", String(format: "%g", $0.intervalSeconds), String(format: "%.6f", $0.cpuPercent)])
        }
        return rows.joined(separator: "\n")
    }
}
