import Darwin
import XCTest
import ThermoKit
@testable import ThermoApp

final class MenuLiveSamplerTests: XCTestCase {
    private func ticks(busy: UInt32, idle: UInt32) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: Int(CPU_STATE_MAX))
        result[Int(CPU_STATE_USER)] = busy
        result[Int(CPU_STATE_IDLE)] = idle
        return result
    }
    func testOnlySelectedResourcesAreReadAndStoppingClearsBaselines() {
        let s = MenuLiveSampler()
        var cpuReads = 0, memoryReads = 0, networkReads = 0
        s.readCPU = { cpuReads += 1; return [10, 0, 0, 10] }
        s.readMemory = { memoryReads += 1; return 100 }
        s.readNetwork = { networkReads += 1; return ["en0": .init(received: 100, sent: 100)] }
        _ = s.sample(metrics: [.cpuUsage, .memory, .download, .upload], now: 1)
        _ = s.sample(metrics: [.fan, .power], now: 2)
        XCTAssertEqual(cpuReads, 1); XCTAssertEqual(memoryReads, 1); XCTAssertEqual(networkReads, 1)
        let restarted = s.sample(metrics: [.cpuUsage, .upload], now: 3)
        XCTAssertNil(restarted.cpu); XCTAssertNil(restarted.upload)
        XCTAssertEqual(networkReads, 2) // download + upload share a single read
    }

    func testCPUShowsBusyShareAndRejectsResetOrWrap() {
        let s = MenuLiveSampler()
        var ticks = self.ticks(busy: 100, idle: 100)
        s.readCPU = { ticks }
        XCTAssertNil(s.sample(metrics: [.cpuUsage], now: 1).cpu)
        ticks = self.ticks(busy: 130, idle: 110)
        XCTAssertEqual(s.sample(metrics: [.cpuUsage], now: 2).cpu, 75)
        ticks = self.ticks(busy: 1, idle: 1)
        XCTAssertNil(s.sample(metrics: [.cpuUsage], now: 3).cpu)
        ticks = self.ticks(busy: .max, idle: .max)
        _ = s.sample(metrics: [.cpuUsage], now: 4)
        ticks = self.ticks(busy: 2, idle: 2)
        XCTAssertNil(s.sample(metrics: [.cpuUsage], now: 5).cpu)
    }

    func testWakeAndLongGapRequireFreshBaselines() {
        let s = MenuLiveSampler()
        var counter: UInt64 = 100
        var tick: UInt32 = 100
        s.readCPU = { [tick, 0, 0, tick] }
        s.readNetwork = { ["en0": .init(received: counter, sent: counter)] }
        _ = s.sample(metrics: [.cpuUsage, .download], now: 1)
        counter += 10; tick += 10
        s.reset()
        let afterWake = s.sample(metrics: [.cpuUsage, .download], now: 2)
        XCTAssertNil(afterWake.cpu); XCTAssertNil(afterWake.download)
        counter += 10; tick += 10
        let gap = s.sample(metrics: [.cpuUsage, .download], now: 40)
        XCTAssertNil(gap.cpu); XCTAssertNil(gap.download)
    }

    func testNetworkRatesRejectInterfaceChangeResetAndWrap() {
        let s = MenuLiveSampler()
        var name = "en0:1", rx: UInt64 = 100, tx: UInt64 = 200
        s.readNetwork = { [name: .init(received: rx, sent: tx)] }
        XCTAssertNil(s.sample(metrics: [.download, .upload], now: 1).download)
        rx = 300; tx = 600
        let rate = s.sample(metrics: [.download, .upload], now: 3)
        XCTAssertEqual(rate.download, 100); XCTAssertEqual(rate.upload, 200)
        name = "en0:2"; rx = 400; tx = 800
        XCTAssertNil(s.sample(metrics: [.download], now: 4).download)
        rx = 1
        XCTAssertNil(s.sample(metrics: [.download], now: 5).download)
        rx = .max; tx = .max
        _ = s.sample(metrics: [.download], now: 6)
        rx = 0; tx = 0
        XCTAssertNil(s.sample(metrics: [.download], now: 7).download)
    }

    func testFailedAndEmptyReadsDoNotBecomeZeroOrReuseOldBaseline() {
        let s = MenuLiveSampler()
        var counters: [String: MenuLiveSampler.Network]? = ["en0": .init(received: 1, sent: 1)]
        var ticks: [UInt32]? = [1, 0, 0, 1]
        s.readNetwork = { counters }; s.readCPU = { ticks }; s.readMemory = { nil }
        _ = s.sample(metrics: [.cpuUsage, .download], now: 1)
        counters = nil; ticks = nil
        let failed = s.sample(metrics: [.cpuUsage, .download, .memory], now: 2)
        XCTAssertNil(failed.cpu); XCTAssertNil(failed.download); XCTAssertNil(failed.memory)
        counters = ["en0": .init(received: 20, sent: 20)]; ticks = [20, 0, 0, 20]
        let recovered = s.sample(metrics: [.cpuUsage, .download], now: 3)
        XCTAssertNil(recovered.cpu); XCTAssertNil(recovered.download)
        counters = [:]
        XCTAssertNil(s.sample(metrics: [.download], now: 4).download)
    }
}
