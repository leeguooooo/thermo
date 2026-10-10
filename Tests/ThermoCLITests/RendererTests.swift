import XCTest
import ThermoKit
@testable import thermo

final class RendererTests: XCTestCase {
    private func snapshot(_ readings: [Reading]) -> Snapshot {
        Snapshot(temperatures: readings, fans: [], power: [], voltages: [], currents: [], battery: nil)
    }

    func testOverviewIncludesBoardAndOtherGroups() {
        let sample = snapshot([
            Reading(key: "board", name: "Board", group: .board, value: 60),
            Reading(key: "other", name: "Other", group: .other, value: 65),
        ])
        let rows = Renderer(style: Style(enabled: false), showAll: false).overview(sample)
        XCTAssertTrue(rows.contains { $0.contains("Board") && $0.contains("60.0°C") })
        XCTAssertTrue(rows.contains { $0.contains("Other") && $0.contains("65.0°C") })
        XCTAssertFalse(rows.contains { $0.contains("no temperature sensors") })
    }

    func testAllOptionIncludesUnnamedGroupReadings() {
        let sample = snapshot([Reading(key: "raw", name: "Raw", group: .other, value: 55, known: false)])
        let normal = Renderer(style: Style(enabled: false), showAll: false).overview(sample)
        let all = Renderer(style: Style(enabled: false), showAll: true).overview(sample)
        XCTAssertTrue(normal.contains { $0.contains("no temperature sensors") })
        XCTAssertTrue(all.contains { $0.contains("Other") && $0.contains("55.0°C") })
    }

    func testAverageDoesNotCountInvalidReadings() {
        let sample = snapshot([
            Reading(key: "valid", name: "CPU", group: .cpu, value: 70),
            Reading(key: "invalid", name: "CPU", group: .cpu, value: .nan),
        ])
        let rows = Renderer(style: Style(enabled: false), showAll: false).overview(sample)
        XCTAssertTrue(rows.contains { $0.contains("70.0°C") })
        XCTAssertFalse(rows.contains { $0.contains("avg") || $0.contains("nan") })
    }
}
