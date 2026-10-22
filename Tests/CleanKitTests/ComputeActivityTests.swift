import XCTest
import AgentCore
@testable import CleanKit

final class ComputeActivityTests: XCTestCase {
    func testCPUOnlySamplingDoesNotReadGPUAndFirstGPUReadHasNoClientBaseline() {
        var calls = 0
        let sampler = ComputeSampler(gpuReader: {
            calls += 1
            return ([GPUDeviceActivity(id: 1, name: "Fixture", percent: 40)], [])
        })
        let cpu = sampler.sample(includeGPU: false)
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(cpu.devices.isEmpty)
        XCTAssertTrue(cpu.programs.allSatisfy { $0.observedGPU == nil })
        XCTAssertEqual(sampler.sample().devices.first?.percent, 40)
        XCTAssertEqual(calls, 1)
    }

    func testCancelledComputationReturnsUnknownWithoutStartingHardwareReads() {
        let sampler = ComputeSampler()
        let result = sampler.sample(cancelled: { true })
        XCTAssertNil(result.cpu)
        XCTAssertTrue(result.devices.isEmpty)
        XCTAssertTrue(result.programs.isEmpty)
        XCTAssertTrue(ProcessTable.usage(uid: nil, cancelled: { true }).isEmpty)
    }

    func testReusedPIDCannotInheritPreviousCPUOrGPUHistory() {
        var old = ProcessUsage(pid: 7, name: "Worker")
        old.started = Date(timeIntervalSince1970: 100)
        var replacement = old
        XCTAssertTrue(ComputeSampler.sameProcess(replacement, old))
        replacement.started = Date(timeIntervalSince1970: 101)
        XCTAssertFalse(ComputeSampler.sameProcess(replacement, old))
        replacement.started = nil
        XCTAssertFalse(ComputeSampler.sameProcess(replacement, old))
    }
    func testRatesPreserveMultipleCoresAndMissingBaselines() {
        XCTAssertEqual(ComputeSampler.rate(5_000_000_000, 1_000_000_000, elapsed: 2_000_000_000), 200)
        XCTAssertNil(ComputeSampler.rate(5, 6, elapsed: 1))
        XCTAssertNil(ComputeSampler.rate(5, 0, elapsed: 0))
        XCTAssertNil(ComputeSampler.rate(5, 0, elapsed: 31_000_000_000))
    }
    func testHostCPUUsesWholeMachineCapacityAndCounterWrap() {
        XCTAssertEqual(ComputeSampler.hostRate([20, 10, 70, 0], [0, 0, 0, 0]), 30)
        XCTAssertNil(ComputeSampler.hostRate([0, 0, 0, 0], [0, 0, 0, 0]))
        XCTAssertEqual(ComputeSampler.hostRate([5, 0, 5, 0], [UInt32.max - 4, 0, 0, 0])!, 100.0 * 10 / 15, accuracy: 0.0001)
    }
    func testGPUCountersPreferDirectValueAndRejectMalformedData() {
        XCTAssertEqual(ComputeSampler.counters(["accumulatedGPUTime": 10, "AppUsage": [["accumulatedGPUTime": 99]]]), [10])
        XCTAssertEqual(ComputeSampler.counters(["AppUsage": [["accumulatedGPUTime": 5], ["accumulatedGPUTime": 6]]]), [5, 6])
        XCTAssertNil(ComputeSampler.counters(["AppUsage": [["API": "Metal"]]]))
        XCTAssertNil(ComputeSampler.counters(["accumulatedGPUTime": true]))
        XCTAssertNil(ComputeSampler.counters(["accumulatedGPUTime": -1]))
        XCTAssertNil(ComputeSampler.percent(101))
        XCTAssertNil(ComputeSampler.percent(true))
        XCTAssertEqual(ComputeSampler.percent(0), 0)
    }
    func testGPUClientResetReplacementAndChangingQueuesEstablishBaseline() {
        let old = GPUClientCounter(id: 1, pid: 2, counters: [1_000_000_000, 1_000_000_000])
        XCTAssertEqual(ComputeSampler.clientRate(.init(id: 1, pid: 2, counters: [2_000_000_000, 2_000_000_000]), old, elapsed: 1_000_000_000), 200)
        XCTAssertNil(ComputeSampler.clientRate(.init(id: 1, pid: 3, counters: old.counters), old, elapsed: 1))
        XCTAssertNil(ComputeSampler.clientRate(.init(id: 1, pid: 2, counters: [2_000_000_000]), old, elapsed: 1))
        XCTAssertNil(ComputeSampler.clientRate(.init(id: 1, pid: 2, counters: [0, 2_000_000_000]), old, elapsed: 1))
    }
    func testProgramCPUDoesNotReportIncompleteSumAsZero() {
        let program = ComputeProgram(id: "fixture", name: "Fixture", processes: [
            .init(pid: 1, name: "Worker", cpu: 200, gpu: 20),
            .init(pid: 2, name: "Helper", cpu: nil, gpu: nil)], contexts: [])
        XCTAssertNil(program.cpu)
        XCTAssertNil(program.gpu)
        XCTAssertEqual(program.observedGPU, 20)
        XCTAssertEqual(program.gpuReportingProcesses, 1)
    }
}
