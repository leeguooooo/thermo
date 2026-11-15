import AgentCore
@testable import AgentDoctor
@testable import PerformanceFeature
import XCTest

final class ProcessExplanationModelTests: XCTestCase {
    final class Gate: @unchecked Sendable {
        let lock=NSLock();let release=DispatchSemaphore(value:0);private var values:[Int32]=[]
        func record(_ pid:Int32) { lock.lock();values.append(pid);lock.unlock() }
        var calls:[Int32] { lock.lock();defer{lock.unlock()};return values }
    }
    @MainActor func testStoppedInspectionCannotOverwriteTheNewTarget() async throws {
        let gate=Gate()
        let model=ProcessExplanationModel(reader:{ expected in
            gate.record(expected.pid)
            if expected.pid==10 { _=gate.release.wait(timeout:.now()+3) }
            return .init(pid:expected.pid,sampled:Date(),chain:[],chainComplete:false,application:nil,attribution:.unknown,observedPaths:nil,pathQueriesComplete:false,pathsTruncated:false,issues:[])
        })
        let first=ProcessIdentity(pid:10,uid:501,started:Date(timeIntervalSince1970:10),executable:"/fixture/A")
        let second=ProcessIdentity(pid:20,uid:501,started:Date(timeIntervalSince1970:20),executable:"/fixture/B")
        model.load(first);model.load(first)
        for _ in 0..<200 where gate.calls.isEmpty { try await Task.sleep(nanoseconds:5_000_000) }
        XCTAssertEqual(gate.calls,[10]);model.stop();model.load(second);gate.release.signal()
        for _ in 0..<200 where model.loading { try await Task.sleep(nanoseconds:5_000_000) }
        XCTAssertFalse(model.loading);XCTAssertEqual(model.report?.pid,20);XCTAssertEqual(gate.calls,[10,20])
        model.stop()
    }
    @MainActor func testRetirementWaitsForPhysicalReadEvenWhenTheWaiterIsCancelled() async {
        let began = expectation(description: "inspection read entered"), returned = expectation(description: "retirement returned")
        let gate = Gate(); defer { gate.release.signal() }
        var releases = 0
        let model = ProcessExplanationModel(reader: { expected in
            gate.record(expected.pid); began.fulfill(); _ = gate.release.wait(timeout: .now()+10)
            return .init(pid:expected.pid,sampled:Date(),chain:[],chainComplete:false,application:nil,attribution:.unknown,observedPaths:nil,pathQueriesComplete:false,pathsTruncated:false,issues:[])
        }, released: { releases += 1 })
        let target = ProcessIdentity(pid:10,uid:501,started:Date(timeIntervalSince1970:10),executable:"/fixture/A")
        model.load(target); await fulfillment(of:[began],timeout:2)
        model.retire(); XCTAssertTrue(model.sampleInFlight); XCTAssertEqual(releases,0)
        let wait = Task { await model.finishStopping(); returned.fulfill() }; wait.cancel()
        gate.release.signal(); await fulfillment(of:[returned],timeout:2); await wait.value
        XCTAssertFalse(model.sampleInFlight); XCTAssertNil(model.report); XCTAssertEqual(releases,1)
        model.load(target); XCTAssertEqual(gate.calls,[10])
    }
    @MainActor func testRetirementBeforeQueuedInspectionSkipsTheReaderAndStillDrains() async {
        let queue = DispatchQueue(label:"inspection.queued"); queue.suspend()
        let model = ProcessExplanationModel(reader: { _ in XCTFail("retired queued read must not run"); throw NSError(domain:"fixture",code:1) },queue:queue)
        model.load(.init(pid:10,uid:501,started:Date(),executable:"/fixture/A"))
        model.retire(); XCTAssertTrue(model.sampleInFlight)
        queue.resume(); await model.finishStopping()
        XCTAssertFalse(model.sampleInFlight); XCTAssertNil(model.report)
    }

}
