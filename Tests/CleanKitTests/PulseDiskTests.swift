import XCTest
@testable import CleanKit
import ThermoL10n

final class PulseDiskTests: XCTestCase {
    override func setUp() { L10n.override = .english }
    override func tearDown() { L10n.override = nil }

    func pulse(free: Int64?, load: Double = 108, thermal: MachinePulse.Thermal = .nominal) -> MachinePulse {
        let wrangler = MachinePulse.Hog(id: "cmd:wrangler", name: "wrangler", cpu: 65, memoryKB: 187_000, pids: [1], quittable: true)
        return MachinePulse(load1: load, load5: 67, cores: 8, thermal: thermal, memory: .normal, swapUsedMB: 10_207,
                            swapTotalMB: 11_008, hogs: [wrangler], sampled: Date(), diskFreeBytes: free)
    }

    func testCriticalCapacityWarnsWithoutSelectingAProgram() {
        let p = pulse(free: 306_000_000)
        XCTAssertEqual(p.verdict, .disk)
        XCTAssertEqual(p.nextStep?.kind, "freeDisk")
        XCTAssertNil(p.nextStep?.program)
        let capacity = MachinePulse.bytes(306_000_000)
        XCTAssertTrue(p.culpritText?.contains(capacity) == true)
        XCTAssertTrue(p.verdictText.contains(capacity))
        XCTAssertNil(p.diskText)
    }

    func testPurgeableSpaceKeepsALowRawFreeFromBeingTheVerdict() {
        var p = pulse(free: 1_000_000_000)
        p.diskAvailableBytes = 40_000_000_000
        XCTAssertNotEqual(p.verdict, .disk)
        XCTAssertNil(p.diskText, "Use the same reported capacity for warning and priority")
        p.diskAvailableBytes = 900_000_000
        XCTAssertEqual(p.verdict, .disk)
    }

    func testHeatStillComesFirst() {
        XCTAssertEqual(pulse(free: 306_000_000, thermal: .critical).verdict, .hot)
        XCTAssertEqual(pulse(free: 306_000_000, thermal: .critical).nextStep?.kind, "pauseWork")
    }

    func testLowButNotFullDiskOnlyWarns() {
        let p = pulse(free: 4_000_000_000, load: 4)
        XCTAssertEqual(p.verdict, .ok)
        XCTAssertNotNil(p.diskText)
        XCTAssertNil(pulse(free: 50_000_000_000, load: 4).diskText)
        XCTAssertNil(pulse(free: nil, load: 4).diskText)
    }

    func testOldReadingsWithoutDiskSpaceStillDecode() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pulse(free: nil))) as! [String: Any]
        json.removeValue(forKey: "diskFreeBytes")
        let decoded = try JSONDecoder().decode(MachinePulse.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.diskFreeBytes)
        XCTAssertEqual(decoded.verdict, .overloaded)
    }
    func testAvailableOnlyCapacityIsUsedInBothDecisionAndDisplayedFacts() {
        var p = pulse(free: nil, load: 0)
        p.diskAvailableBytes = 900_000_000
        XCTAssertEqual(p.effectiveDiskAvailableBytes, 900_000_000)
        XCTAssertEqual(p.verdict, .disk)
        XCTAssertTrue(p.verdictText.contains(MachinePulse.bytes(900_000_000)))
        XCTAssertTrue(p.culpritText?.contains(MachinePulse.bytes(900_000_000)) == true)
    }

    func testInvalidCapacityIsUnknownAndValidZeroIsRetained() {
        var p = pulse(free: -1, load: 0)
        p.diskAvailableBytes = -1
        XCTAssertNil(p.effectiveDiskAvailableBytes)
        XCTAssertNotEqual(p.verdict, .disk)
        XCTAssertNil(p.diskText)
        p.diskFreeBytes = 4_000_000_000
        XCTAssertEqual(p.effectiveDiskAvailableBytes, 4_000_000_000)
        XCTAssertNotNil(p.diskText)
        p.diskAvailableBytes = 0
        XCTAssertEqual(p.effectiveDiskAvailableBytes, 0)
        XCTAssertEqual(p.verdict, .disk)
    }

    func testReportedCapacityOverridesRawFreeInDisplayedContext() {
        var p = pulse(free: 10_000_000_000, load: 0)
        p.diskAvailableBytes = 700_000_000
        XCTAssertTrue(p.verdictText.contains(MachinePulse.bytes(700_000_000)))
        XCTAssertFalse(p.verdictText.contains(MachinePulse.bytes(10_000_000_000)))
        XCTAssertTrue(p.culpritText?.contains(MachinePulse.bytes(700_000_000)) == true)
    }

    func testCPUContextUsesHighestObservedProcessEvenWhenRowsAreMemoryOrdered() {
        var p = pulse(free: nil, load: 4)
        let largeMemory = MachinePulse.Hog(id: "memory", name: "Large memory", cpu: 0, memoryKB: 2_000_000, pids: [1], quittable: true)
        let busy = MachinePulse.Hog(id: "cpu", name: "Busy worker", cpu: 200, memoryKB: 10_000, pids: [2], quittable: true)
        p.hogs = [largeMemory, busy]
        XCTAssertTrue(p.culpritText?.contains("Busy worker") == true)
        XCTAssertFalse(p.culpritText?.contains("Large memory") == true)
    }

    func testSwapSizeDoesNotTurnUnknownMemoryPressureIntoHighPressure() {
        var p = pulse(free: nil, load: 9)
        p.hogs = []
        p.memory = .unknown
        XCTAssertTrue(p.culpritText?.contains("unavailable") == true)
        p.memory = .normal
        XCTAssertTrue(p.culpritText?.contains("normal memory pressure") == true)
    }

    func testUnavailableMemoryMeasurementCannotSelectAnAppToQuit() {
        var p = pulse(free: nil, load: 0)
        p.memory = .warning
        var unknown = MachinePulse.Hog(id: "unknown", name: "Unknown memory", cpu: 0, memoryKB: 8_000_000, pids: [1], quittable: true)
        unknown.memoryMetric = .unavailable
        var known = MachinePulse.Hog(id: "known", name: "Known memory", cpu: 0, memoryKB: 1_000_000, pids: [2], quittable: true)
        known.memoryMetric = .footprint
        p.hogs = [unknown, known]
        XCTAssertEqual(p.nextStep?.program, "Known memory")
        XCTAssertTrue(p.culpritText?.contains("Known memory") == true)
        XCTAssertFalse(p.culpritText?.contains("Unknown memory") == true)
    }

}
