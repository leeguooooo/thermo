import XCTest
import ThermoKit
@testable import ThermoApp

final class MenuDisplayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100)
    private func snapshot(temperatures: [Reading] = [], fans: [FanReading] = [], timestamp: Date? = nil) -> Snapshot {
        Snapshot(timestamp: timestamp ?? now, temperatures: temperatures, fans: fans, power: [],
                 voltages: [], currents: [], battery: nil)
    }

    func testMissingCPUAndPowerNeverDisplayAnotherSensorsTemperature() {
        let s = snapshot(temperatures: [.init(key: "gpu", name: "GPU", group: .gpu, value: 77)])
        var p = MenuBarPreferences(); p.secondary = .power; p.presentation = .data
        let display = MenuDisplay.make(preferences: p, snapshot: s, live: .init(), fahrenheit: false, now: now)
        XCTAssertFalse(display.text.isEmpty) // data-only unknown retains a clickable title
        XCTAssertFalse(display.text.contains("77"))
        XCTAssertTrue(display.text.contains("—")); XCTAssertTrue(display.tooltip.contains("°C"))
        XCTAssertTrue(display.tooltip.contains("W")); XCTAssertFalse(display.showIcon)
    }

    func testPartialFanReadingIsExplicitlyALowerBound() {
        let fans: [FanReading] = [
            .init(id: 0, name: "left", rpm: 2000, min: nil, max: nil, target: nil, manual: nil),
            .init(id: 1, name: "right", rpm: nil, min: nil, max: nil, target: nil, manual: nil),
        ]
        var p = MenuBarPreferences(); p.primary = .fan
        let d = MenuDisplay.make(preferences: p, snapshot: snapshot(fans: fans), live: .init(), fahrenheit: false, now: now)
        XCTAssertTrue(d.text.contains("≥")); XCTAssertTrue(d.tooltip.contains("rpm"))
        let missing = MenuDisplay.make(preferences: p, snapshot: snapshot(), live: .init(), fahrenheit: false, now: now)
        XCTAssertTrue(missing.text.contains("—")); XCTAssertFalse(missing.text.contains("0 rpm"))
    }

    func testTwoLinesIconOptionsAndAwakeMarker() {
        var p = MenuBarPreferences(); p.secondary = .memory; p.layout = .stacked
        let live = MenuLiveValues(sampled: now, memory: 8 * 1_073_741_824)
        let stacked = MenuDisplay.make(preferences: p, snapshot: nil, live: live, fahrenheit: false, marker: "☕︎", now: now)
        XCTAssertTrue(stacked.stacked); XCTAssertTrue(stacked.text.contains("\n")); XCTAssertTrue(stacked.showIcon)
        XCTAssertTrue(stacked.text.contains("☕︎")); XCTAssertTrue(stacked.tooltip.contains("GiB"))
        p.presentation = .icon
        let icon = MenuDisplay.make(preferences: p, snapshot: nil, live: live, fahrenheit: false, marker: "☕︎", now: now)
        XCTAssertEqual(icon.text, "☕︎"); XCTAssertTrue(icon.showIcon); XCTAssertFalse(icon.stacked)
        p.presentation = .data; p.secondary = nil
        let single = MenuDisplay.make(preferences: p, snapshot: nil, live: live, fahrenheit: false, now: now)
        XCTAssertFalse(single.stacked); XCTAssertFalse(single.text.contains("\n")); XCTAssertFalse(single.showIcon)
    }

    func testStaleValuesBecomeUnknownAndKeepUnits() {
        var p = MenuBarPreferences(); p.primary = .cpuUsage; p.secondary = .download
        let live = MenuLiveValues(sampled: now.addingTimeInterval(-16), cpu: 88, download: 1024)
        let d = MenuDisplay.make(preferences: p, snapshot: nil, live: live, fahrenheit: false, now: now)
        XCTAssertFalse(d.text.contains("88")); XCTAssertTrue(d.text.contains("— %"))
        XCTAssertTrue(d.tooltip.contains("KiB/s"))
        p.primary = .cpu; p.secondary = nil
        let stale = snapshot(temperatures: [.init(key: "cpu", name: "CPU", group: .cpu, value: 77)], timestamp: now.addingTimeInterval(-16))
        let sensor = MenuDisplay.make(preferences: p, snapshot: stale, live: live, fahrenheit: true, now: now)
        XCTAssertTrue(sensor.text.contains("— °F")); XCTAssertFalse(sensor.text.contains("171"))
    }

    func testLateSensorCompletionDoesNotRefreshOldObservations() {
        let p = MenuBarPreferences()
        let s = snapshot(temperatures: [.init(key: "cpu", name: "CPU", group: .cpu, value: 77)])
        let d = MenuDisplay.make(preferences: p, snapshot: s, live: .init(), fahrenheit: false, now: now,
                                 sensorReadStarted: now.addingTimeInterval(-16))
        XCTAssertTrue(d.text.contains("— °C")); XCTAssertFalse(d.text.contains("77"))
    }

    func testWakeOrSettingsBoundaryRejectsReadsStartedBeforeIt() {
        var p = MenuBarPreferences(); p.secondary = .memory
        let s = snapshot(temperatures: [.init(key: "cpu", name: "CPU", group: .cpu, value: 77)])
        let started = now.addingTimeInterval(-2)
        let live = MenuLiveValues(sampled: started, memory: 8 * 1_073_741_824)
        let d = MenuDisplay.make(preferences: p, snapshot: s, live: live, fahrenheit: false, now: now,
                                 sensorReadStarted: started, validAfter: now.addingTimeInterval(-1))
        XCTAssertTrue(d.text.contains("— °C")); XCTAssertTrue(d.text.contains("— GiB"))
        let fresh = MenuDisplay.make(preferences: p, snapshot: s, live: .init(sampled: now, memory: 8 * 1_073_741_824),
                                     fahrenheit: false, now: now, sensorReadStarted: now,
                                     validAfter: now.addingTimeInterval(-1))
        XCTAssertTrue(fresh.text.contains("77 °C")); XCTAssertTrue(fresh.text.contains("8 GiB"))
    }
}
