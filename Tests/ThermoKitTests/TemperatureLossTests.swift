import XCTest
@testable import ThermoKit

final class TemperatureLossTests: XCTestCase {
    func testPreviouslyObservedOrExplicitlyRequiredGPUCannotDisappearDuringCooling() {
        var engine = FanPolicyEngine(limits: limits)
        engine.set(.fixed(rpm: 2000), for: 0)
        _ = engine.tick(snapshot(cpu: 50, gpu: 100))
        XCTAssertEqual(engine.tick(snapshot(cpu: 50, gpu: 100)), [.failsafe(temperature: 100)])
        XCTAssertEqual(engine.tick(snapshot(cpu: 50)), [.temperatureUnavailable])
        for _ in 0..<10 { XCTAssertEqual(engine.tick(snapshot(cpu: 50)), []) }
        XCTAssertTrue(engine.suspended)
        XCTAssertEqual(engine.tick(snapshot(cpu: 50, gpu: 50)), [])
        XCTAssertEqual(engine.tick(snapshot(cpu: 50, gpu: 50)), [])
        XCTAssertEqual(engine.tick(snapshot(cpu: 50, gpu: 50)), [.resume(temperature: 50), .manual(fan: 0, rpm: 2000)])
        var expected = FanPolicyEngine(limits: limits, requiresGPU: true)
        expected.set(.fixed(rpm: 2000), for: 0)
        XCTAssertEqual(expected.tick(snapshot(cpu: 50)), [.temperatureUnavailable])
        var shared = FanPolicyEngine(limits: limits)
        XCTAssertEqual(shared.observeControlTemperature(snapshot(cpu: 50, gpu: 70)), 70)
        XCTAssertNil(shared.observeControlTemperature(snapshot(cpu: 50)), "lid-awake telemetry loss must share the same coverage rule")
    }
    let limits = SafetyLimits(ceiling: 95, resumeBelow: 85, resumeTicks: 3, triggerTicks: 2)
    func snapshot(cpu: Double? = nil, gpu: Double? = nil, extra: [Reading] = []) -> Snapshot {
        var readings = extra
        if let cpu { readings.append(.init(key: "TC0P", name: "CPU", group: .cpu, value: cpu)) }
        if let gpu { readings.append(.init(key: "TG0P", name: "GPU", group: .gpu, value: gpu)) }
        return Snapshot(temperatures: readings,
            fans: [FanReading(id: 0, name: "Left", rpm: 2000, min: 1200, max: 6000, target: nil, manual: true),
                   FanReading(id: 1, name: "Right", rpm: 2000, min: 1200, max: 6000, target: nil, manual: true)],
            power: [], voltages: [], currents: [], battery: nil)
    }

    func testBoardBatteryAndGPUCannotReplaceRequiredCPUTelemetry() {
        let sample = snapshot(gpu: 50, extra: [.init(key: "battery", name: "Battery", group: .battery, value: 30)])
        XCTAssertEqual(sample.hottest, 50, "display behavior remains available")
        XCTAssertNil(sample.controlTemperature())
        var engine = FanPolicyEngine(limits: limits); engine.set(.fixed(rpm: 2000), for: 0)
        XCTAssertEqual(engine.tick(sample), [.temperatureUnavailable])
        XCTAssertTrue(engine.suspended)
        XCTAssertEqual(engine.suspensionReason, .temperatureUnavailable)
        XCTAssertEqual(engine.tick(sample), [], "do not repeat a transition/log every tick")
        XCTAssertEqual(engine.policies[0], .fixed(rpm: 2000))
    }

    func testMissingInvalidOrUnknownCPUReadingsCannotBeTreatedAsCold() {
        for cpu in [Double.nan, Double.infinity, -1, 0] {
            var engine = FanPolicyEngine(limits: limits); engine.set(.fixed(rpm: 2000), for: 0)
            XCTAssertEqual(engine.tick(snapshot(cpu: cpu, gpu: 40)), [.temperatureUnavailable])
        }
        let unknown = snapshot(extra: [.init(key: "unknown", name: "CPU", group: .cpu, value: 50, known: false)])
        XCTAssertNil(unknown.controlTemperature())
    }

    func testTelemetryLossInterruptsCoolingWindowAndRequiresNewConsecutiveSafeReadings() {
        var engine = FanPolicyEngine(limits: limits); engine.set(.fixed(rpm: 2000), for: 0)
        _ = engine.tick(snapshot())
        XCTAssertEqual(engine.tick(snapshot(cpu: 50)), [])
        XCTAssertEqual(engine.tick(snapshot(cpu: 50)), [])
        XCTAssertEqual(engine.tick(snapshot()), [])
        XCTAssertEqual(engine.tick(snapshot(cpu: 50)), [])
        XCTAssertEqual(engine.tick(snapshot(cpu: 90)), [], "valid but warm is not a cooling sample")
        XCTAssertEqual(engine.tick(snapshot(cpu: 50)), [])
        XCTAssertEqual(engine.tick(snapshot(cpu: 50)), [])
        XCTAssertEqual(engine.tick(snapshot(cpu: 50)), [.resume(temperature: 50), .manual(fan: 0, rpm: 2000)])
        XCTAssertFalse(engine.suspended); XCTAssertNil(engine.suspensionReason)
    }

    func testHotReturnSwitchesToThermalProtectionWithoutResumingLowCooling() {
        var engine = FanPolicyEngine(limits: limits); engine.set(.fixed(rpm: 2000), for: 0)
        _ = engine.tick(snapshot())
        XCTAssertEqual(engine.tick(snapshot(cpu: 97)), [.failsafe(temperature: 97)])
        XCTAssertEqual(engine.suspensionReason, .thermal)
        XCTAssertEqual(engine.tick(snapshot(cpu: 99)), [])
    }

    func testMaximumCoolingContinuesDuringLossAndMixedPoliciesKeepLowCoolingSuspended() {
        var engine = FanPolicyEngine(limits: limits); engine.set(.fixed(rpm: 5700), for: 0)
        XCTAssertEqual(engine.tick(snapshot()), [.manual(fan: 0, rpm: 6000)], "without telemetry use the actual maximum for the full-cooling exception")
        XCTAssertFalse(engine.suspended)
        engine.set(.curve(.quiet), for: 1)
        XCTAssertEqual(engine.tick(snapshot()), [.temperatureUnavailable, .manual(fan: 0, rpm: 6000)])
        XCTAssertTrue(engine.suspended)
        XCTAssertEqual(engine.tick(snapshot()), [.manual(fan: 0, rpm: 6000)])
    }

    func testCurveUsesChosenSensorInsteadOfSubstitutingCPUForMissingGPU() {
        var engine = FanPolicyEngine(limits: limits)
        engine.set(.curve(FanCurve(points: [.init(50, 2000)], sensor: .gpu)), for: 0)
        XCTAssertEqual(engine.tick(snapshot(cpu: 60)), [.auto(fan: 0)])
        XCTAssertEqual(engine.tick(snapshot(cpu: 60, gpu: 70)), [.manual(fan: 0, rpm: 2000)])
        let storageHot = snapshot(cpu: 50, gpu: 60, extra: [.init(key: "disk", name: "Disk", group: .storage, value: 120)])
        XCTAssertEqual(storageHot.maximumKnownTemperature, 120)
        XCTAssertEqual(storageHot.controlTemperature(), 60)
    }
}
