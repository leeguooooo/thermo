import AgentCore
@testable import AgentDoctor
@testable import ThermoApp
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
}
