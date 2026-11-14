@testable import CleanKit
import Foundation
import XCTest
@testable import ThermoApp

@MainActor final class PulseRecorderLifetimeTests: XCTestCase {
    final class Reader: @unchecked Sendable {
        let entered: XCTestExpectation
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var reads = 0
        init(_ entered: XCTestExpectation) { self.entered = entered }
        var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
        func records() -> [PulseRecord] {
            lock.lock(); reads += 1; let index = reads; lock.unlock()
            if index == 1 { entered.fulfill(); release.wait() }
            let pulse = MachinePulse(load1: Double(index), load5: 0, cores: 8, thermal: .nominal,
                                     memory: .normal, swapUsedMB: 0, hogs: [], sampled: Date())
            return [PulseRecord(pulse, memory: nil)]
        }
    }
    func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { done in queue.async { DispatchQueue.main.async { done.resume() } } }
    }
    func testStopDrainsBlockedHistoryReadAndRejectsItsPublication() async {
        let entered = expectation(description: "history reader started"), reader = Reader(entered)
        let queue = DispatchQueue(label: "thermo-test-pulse-recorder"), recorder = PulseRecorder(queue: queue, readHistory: { reader.records() })
        recorder.start(); recorder.start()
        await fulfillment(of: [entered], timeout: 2)
        recorder.beginStopping()
        reader.release.signal()
        await recorder.stop(); await drain(queue)
        XCTAssertEqual(reader.count, 1, "repeated start does not schedule duplicate history passes")
        XCTAssertTrue(recorder.recent.isEmpty, "a retired read cannot publish into the UI")
        recorder.start(); await drain(queue)
        XCTAssertEqual(reader.count, 2)
        XCTAssertEqual(recorder.recent.first?.load1, 2)
        await recorder.stop()
    }
    func testAReplacedSamplingTokenNeverAcceptsTheRetiredResult() {
        let lifetime = FeatureSamplingLifetime(), first = lifetime.start()
        XCTAssertTrue(lifetime.accepts(first))
        lifetime.stop(); XCTAssertFalse(lifetime.accepts(first))
        let second = lifetime.start()
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(lifetime.accepts(first))
        XCTAssertTrue(lifetime.accepts(second))
    }
}
