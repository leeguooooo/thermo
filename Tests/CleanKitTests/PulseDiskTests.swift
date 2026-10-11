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

    func testAFullDiskIsTheVerdictNotTheBusiestProgram() {
        let p = pulse(free: 306_000_000)
        XCTAssertEqual(p.verdict, .disk)
        XCTAssertEqual(p.nextStep?.kind, "freeDisk")
        XCTAssertNil(p.nextStep?.program)
        XCTAssertTrue(p.culpritText?.contains("cannot grow swap") == true)
        XCTAssertTrue(p.verdictText.contains("almost full"))
        XCTAssertNil(p.diskText)
    }

    func testPurgeableSpaceKeepsALowRawFreeFromBeingTheVerdict() {
        var p = pulse(free: 1_000_000_000)
        p.diskAvailableBytes = 40_000_000_000
        XCTAssertNotEqual(p.verdict, .disk, "macOS purges snapshots before the disk is really full")
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
}
