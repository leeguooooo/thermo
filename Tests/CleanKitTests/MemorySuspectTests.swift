@testable import CleanKit
import XCTest

final class MemorySuspectTests: XCTestCase {
    let now = Date()

    func hog(_ id: String, mb: Int, up: TimeInterval? = nil, quittable: Bool = true) -> MachinePulse.Hog {
        var h = MachinePulse.Hog(id: id, name: id, cpu: 0, memoryKB: mb * 1024, pids: [1], app: "/Applications/\(id).app", quittable: quittable)
        h.uptime = up
        return h
    }

    func history(_ id: String, _ mbs: [Int], every: TimeInterval = 1200) -> [ProgramMemoryRecord] {
        mbs.enumerated().map { i, mb in
            ProgramMemoryRecord(t: now.addingTimeInterval(-Double(mbs.count - i) * every), programs: [id: mb * 1024], names: [id: id])
        }
    }

    func testSteadyGrowthIsALeakSuspect() {
        let s = MemorySuspects.find(programs: [hog("Slack", mb: 1400)], history: history("Slack", [500, 700, 900, 1200]), now: now)
        XCTAssertEqual(s.first?.kind, .growing)
        XCTAssertEqual(s.first?.grewKB, 900 * 1024)
    }

    func testGrowingThenComingDownIsJustWork() {
        let s = MemorySuspects.find(programs: [hog("Xcode", mb: 900)], history: history("Xcode", [500, 1500, 2000, 1800]), now: now)
        XCTAssertTrue(s.isEmpty)
    }

    func testBigAppRunningForDaysIsWorthARestart() {
        let s = MemorySuspects.find(programs: [hog("Xcode", mb: 2400, up: 26 * 3600), hog("Notes", mb: 300, up: 9 * 86400)], history: [], now: now)
        XCTAssertEqual(s.map(\.name), ["Xcode"])
        XCTAssertEqual(s.first?.kind, .longRunning)
    }

    func testAgentsAndSystemProcessesAreNeverSuggested() {
        let s = MemorySuspects.find(programs: [hog("claude", mb: 3000, up: 3 * 86400, quittable: false)], history: [], now: now)
        XCTAssertTrue(s.isEmpty)
    }

    func testFullDiskBlocksSwap() {
        var b = MemoryBreakdown(total: 16 << 30, app: 3 << 30, wired: 4 << 30, compressed: 4 << 30, compressedHolds: 9 << 30, cached: 1 << 30,
                                free: 1 << 30, pressure: .normal, swapUsed: 10 << 30, swapFiles: 11 << 30, diskFree: 300 << 20,
                                swapOuts: 0, swapIns: 0, sampled: now)
        XCTAssertTrue(b.swapBlocked)
        b.diskFree = 40 << 30
        XCTAssertFalse(b.swapBlocked)
        XCTAssertEqual(b.used, 11 << 30)
    }
}
