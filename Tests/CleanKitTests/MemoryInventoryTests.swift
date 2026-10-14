import AgentCore
import Darwin
import XCTest
@testable import CleanKit

final class MemoryInventoryTests: XCTestCase {
    func process(_ pid: Int32, project: String, footprint: Int?, rss: Int?) -> AgentProcess {
        var p = AgentProcess(pid: pid, name: "rea", executable: "/fixture/rea", argv: ["rea"], cwd: project)
        p.memoryReading = ProcessMemoryReading(footprintKB: footprint, residentKB: rss)
        return p
    }

    func testNamesMergeAcrossProjectsWithoutExpandingActionScope() throws {
        let contexts = MachinePulse.group([process(10, project: "/p/shop", footprint: 100, rss: 50),
                                           process(11, project: "/p/admin", footprint: 200, rss: 60),
                                           process(12, project: "/p/shop", footprint: 300, rss: 70)], limit: nil)
        let group = try XCTUnwrap(MemoryInventory.group(contexts).first)
        XCTAssertEqual(MemoryInventory.group(contexts).count, 1)
        XCTAssertEqual(group.processCount, 3)
        XCTAssertEqual(group.memoryKB, 600)
        XCTAssertEqual(group.residentKB, 180)
        XCTAssertEqual(group.projects, ["/p/admin", "/p/shop"])
        XCTAssertNil(group.actionTarget, "a merged display group is never an End target")
        XCTAssertFalse(group.historyEntry.quittable)
        XCTAssertEqual(group.contexts.first { $0.project == "/p/admin" }?.pids, [11])
        XCTAssertEqual(group.contexts.first { $0.project == "/p/shop" }?.parts?.count, 2)
    }

    func testRSSDoesNotInflateFootprintOrBecomeSwap() throws {
        let h = try XCTUnwrap(MachinePulse.group([process(10, project: "/p", footprint: 100, rss: 1000)], limit: nil).first)
        XCTAssertEqual(h.memoryKB, 100)
        XCTAssertEqual(h.residentKB, 1000)
        XCTAssertEqual(h.memoryMetric, .footprint)
    }

    func testUnavailableReadingIsNotAZeroMeasurement() throws {
        let contexts = MachinePulse.group([process(10, project: "/p", footprint: nil, rss: nil),
                                           process(11, project: "/q", footprint: nil, rss: 400)], limit: nil)
        XCTAssertEqual(contexts.first { $0.pids == [10] }?.memoryMetric, .unavailable)
        XCTAssertNil(contexts.first { $0.pids == [10] }?.residentKB)
        XCTAssertEqual(contexts.first { $0.pids == [11] }?.memoryMetric, .residentEstimate)
        let group = try XCTUnwrap(MemoryInventory.group(contexts).first)
        XCTAssertEqual(group.memoryMetric, .mixed)
        XCTAssertNil(group.footprintKB)
        XCTAssertNil(group.residentKB)
    }

    func testPartialRSSIsNotShownAsComplete() throws {
        let h = try XCTUnwrap(MachinePulse.group([process(10, project: "/p", footprint: 100, rss: 50),
                                                process(11, project: "/p", footprint: 200, rss: nil)], limit: nil).first)
        XCTAssertNil(h.residentKB)
        XCTAssertEqual(h.memoryKB, 300)
    }

    func testAgentsStayProtectedInsideMergedGroups() {
        let contexts = MachinePulse.group([AgentProcess(pid: 10, name: "claude", argv: ["claude"], cwd: "/p"),
                                           AgentProcess(pid: 11, name: "claude", argv: ["claude"], cwd: "/q")], limit: nil)
        XCTAssertTrue(MemoryInventory.group(contexts).allSatisfy { $0.contexts.allSatisfy { !$0.quittable } })
    }

    func testCounterRatesRejectResetAndStaleIntervals() {
        let now = Date()
        var before = MemoryBreakdown(total: 16 << 30, app: 0, wired: 0, compressed: 0, compressedHolds: 0,
                                     cached: 0, free: 0, pressure: .normal, swapUsed: 8 << 30, swapFiles: 10 << 30,
                                     diskFree: nil, swapOuts: 10, swapIns: 20, sampled: now)
        var after = before
        after.sampled = now.addingTimeInterval(5)
        after.swapIns += 10; after.swapOuts += 20
        XCTAssertEqual(MemoryActivity(previous: before, current: after, pageSize: 4096)?.swapReadBytesPerSecond, 8192)
        XCTAssertEqual(MemoryActivity(previous: before, current: after, pageSize: 4096)?.swapWriteBytesPerSecond, 16384)
        after.swapIns = 0
        XCTAssertNil(MemoryActivity(previous: before, current: after))
        after = before; after.sampled = now.addingTimeInterval(120)
        XCTAssertNil(MemoryActivity(previous: before, current: after))
        before.diskFree = 1 << 30; before.diskAvailable = 30 << 30
        XCTAssertFalse(before.swapBlocked, "purgeable capacity must be considered")
    }

    func testAppAndCLIWithSameNameKeepDifferentActions() {
        let contexts = [MachinePulse.Hog(id: "app", name: "Claude", cpu: 0, memoryKB: 100, pids: [10], app: "/fixture/Claude.app", quittable: true),
                        MachinePulse.Hog(id: "cmd", name: "claude", cpu: 0, memoryKB: 200, pids: [11], quittable: false)]
        XCTAssertEqual(MemoryInventory.group(contexts).count, 2)
        XCTAssertEqual(MemoryInventory.group(contexts).first { $0.app != nil }?.actionTarget?.pids, [10])
    }

    func testExportContainsDerivedTotalsAndPreservesContexts() throws {
        let contexts = MachinePulse.group([process(10, project: "/p", footprint: 100, rss: 50)], limit: nil)
        let program = try XCTUnwrap(MemoryInventory.group(contexts).first)
        let data = try JSONEncoder().encode(program)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["memoryKB"] as? Int, 100)
        XCTAssertEqual(json["footprintKB"] as? Int, 100)
        XCTAssertEqual(json["residentKB"] as? Int, 50)
        XCTAssertEqual(json["processCount"] as? Int, 1)
        XCTAssertEqual(try JSONDecoder().decode(MemoryProgram.self, from: data), program)
    }

    func testUnknownPressureDoesNotGenerateMemoryAction() {
        let p = MachinePulse(load1: 0, load5: 0, cores: 8, thermal: .nominal, memory: .unknown,
                             swapUsedMB: 0, hogs: [], sampled: Date())
        XCTAssertFalse(p.memory.isHigh)
        XCTAssertEqual(p.verdict, .ok)
        XCTAssertNil(p.nextStep)
    }

    func testLiveProcessReadingUsesExplicitSourceAndConsistentIdentity() throws {
        let reading = ProcessTable.memory(getpid())
        XCTAssertGreaterThan(try XCTUnwrap(reading.footprintKB), 0)
        XCTAssertGreaterThan(try XCTUnwrap(reading.residentKB), 0)
        let p = try XCTUnwrap(ProcessTable.current(.init(cpu: false)).entries.first { $0.pid == getpid() })
        XCTAssertEqual(p.sampledIdentity, ProcessTable.identity(getpid()))
        XCTAssertNotNil(p.memoryReading?.footprintKB)
    }
}
