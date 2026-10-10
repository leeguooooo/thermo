import XCTest
import ThermoKit

final class SnapshotTemperatureTests: XCTestCase {
    private func snapshot(_ readings: [Reading]) -> Snapshot {
        Snapshot(temperatures: readings, fans: [], power: [], voltages: [], currents: [], battery: nil)
    }

    func testDisplayMaximumIncludesStorageWithoutChangingFanControlTemperature() {
        let sample = snapshot([
            Reading(key: "cpu", name: "CPU", group: .cpu, value: 70),
            Reading(key: "gpu", name: "GPU", group: .gpu, value: 75),
            Reading(key: "disk", name: "Storage", group: .storage, value: 95),
        ])
        XCTAssertEqual(sample.maximumKnownTemperature, 95)
        XCTAssertEqual(sample.hottest, 75)
        XCTAssertEqual(sample.temperature(for: .max), 75)
    }

    func testUnknownAndNonfiniteReadingsDoNotBecomeDisplayMaximum() {
        let sample = snapshot([
            Reading(key: "unknown", name: "Unknown", group: .other, value: 120, known: false),
            Reading(key: "invalid", name: "CPU", group: .cpu, value: .infinity),
            Reading(key: "nan", name: "GPU", group: .gpu, value: .nan),
            Reading(key: "board", name: "Board", group: .board, value: 60),
        ])
        XCTAssertEqual(sample.maximumKnownTemperature, 60)
        XCTAssertEqual(sample.hottest, 60)
        XCTAssertNil(sample.cpu)
        XCTAssertNil(sample.averageTemperature(in: .gpu))
    }

    func testEmptySnapshotHasNoMaximum() {
        XCTAssertNil(snapshot([]).maximumKnownTemperature)
        XCTAssertNil(snapshot([]).hottest)
    }
}
