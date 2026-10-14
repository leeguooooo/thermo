@testable import CleanKit
import XCTest
import AgentCore

final class MemorySuspectTests: XCTestCase {
    let now = Date()
    var identity: ProcessIdentity { ProcessIdentity(pid: 1, uid: 501, started: now.addingTimeInterval(-86400), executable: "/fixture/tool") }

    func hog(_ id: String, mb: Int, up: TimeInterval? = nil, quittable: Bool = true) -> MachinePulse.Hog {
        var h = MachinePulse.Hog(id: id, name: id, cpu: 0, memoryKB: mb * 1024, pids: [1], app: "/Applications/\(id).app", quittable: quittable)
        h.uptime = up
        h.processIdentities = [identity]
        return h
    }

    func history(_ id: String, _ mbs: [Int], every: TimeInterval = 1200) -> [ProgramMemoryRecord] {
        mbs.enumerated().map { i, mb in
            var r = ProgramMemoryRecord(t: now.addingTimeInterval(-Double(mbs.count - i) * every), programs: [id: mb * 1024], names: [id: id])
            r.identities = [id: [identity]]
            return r
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

    func testAgeAndSizeAloneDoNotSuggestRestart() {
        let s = MemorySuspects.find(programs: [hog("Xcode", mb: 2400, up: 26 * 3600), hog("Notes", mb: 300, up: 9 * 86400)], history: [], now: now)
        XCTAssertTrue(s.isEmpty)
    }

    func testAgentsAndSystemProcessesAreNeverSuggested() {
        let s = MemorySuspects.find(programs: [hog("claude", mb: 3000, up: 3 * 86400, quittable: false)], history: [], now: now)
        XCTAssertTrue(s.isEmpty)
    }


    func testRestartedProcessAndLegacyRecordsDoNotBecomeGrowth() {
        var h = hog("Tool", mb: 1800)
        h.processIdentities = [ProcessIdentity(pid: 1, uid: 501, started: now.addingTimeInterval(-60), executable: "/fixture/tool")]
        XCTAssertTrue(MemorySuspects.find(programs: [h], history: history("Tool", [500, 700, 900, 1200]), now: now).isEmpty)
        let legacy = history("Tool", [500, 700, 900, 1200]).map { r in var r = r; r.identities = nil; return r }
        XCTAssertTrue(MemorySuspects.find(programs: [hog("Tool", mb: 1800)], history: legacy, now: now).isEmpty)
    }

    func testResidentFallbackDoesNotBecomeFootprintGrowth() {
        var h = hog("Tool", mb: 1800)
        h.memoryMetric = .residentEstimate
        XCTAssertTrue(MemorySuspects.find(programs: [h], history: history("Tool", [500, 700, 900, 1200]), now: now).isEmpty)
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
