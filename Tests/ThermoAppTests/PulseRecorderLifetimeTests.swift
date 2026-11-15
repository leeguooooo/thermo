import Combine
import NativeFeatureAPI
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
    func testClosedRecorderNeverLoadsHistoryEvenWhenAskedToStart() async {
        let reader = Reader(XCTestExpectation(description: "unused history reader"))
        reader.release.signal()
        let queue = DispatchQueue(label: "thermo-closed-recorder")
        let recorder = PulseRecorder(queue: queue, readHistory: { reader.records() }, samplingAllowed: { false })
        recorder.start(); recorder.start()
        await recorder.stop(); await drain(queue)
        XCTAssertEqual(reader.count, 0)
        XCTAssertTrue(recorder.recent.isEmpty)
    }
    func testManualDiagnosisCannotPublishAfterItsSessionStops() async {
        let entered = expectation(description: "manual diagnosis entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let queue = DispatchQueue(label: "thermo-manual-diagnosis-retirement")
        let system = SlowdownSystem(memoryBytes: 16 << 30, swapUsed: 0, swapTotal: 0,
                                    pressure: .normal, load1: 1, cores: 8)
        let found = SlowdownDiagnosis(sampled: Date(), system: system, memoryStrain: .none,
                                      cpuStrain: .none, headline: "Fixture", culprits: [], also: [])
        let recorder = PulseRecorder(queue: queue, readHistory: { [] }, readDiagnosis: {
            entered.fulfill(); _ = release.wait(timeout: .now() + 10)
            return (found, [])
        })
        var published: [String] = []
        let observation = recorder.$diagnosis.compactMap { $0 }.sink { published.append($0.headline) }
        recorder.start(); await drain(queue)
        recorder.diagnoseNow()
        await fulfillment(of: [entered], timeout: 2)
        recorder.beginStopping()
        release.signal()
        await recorder.stop(); await drain(queue)
        XCTAssertTrue(published.isEmpty, "An explicit refresh must obey the same publication lifetime as periodic diagnosis")
        XCTAssertNil(recorder.diagnosis)
        withExtendedLifetime(observation) {}
    }

    func testFreshDiagnosisCompletesAsSkippedAfterRetirementWithoutCallingTheAction() async {
        let entered = expectation(description: "fresh diagnosis entered")
        let skipped = expectation(description: "caller can release its operation")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let queue = DispatchQueue(label: "thermo-fresh-diagnosis-retirement")
        let system = SlowdownSystem(memoryBytes: 16 << 30, swapUsed: 0, swapTotal: 0,
                                    pressure: .normal, load1: 1, cores: 8)
        let found = SlowdownDiagnosis(sampled: Date(), system: system, memoryStrain: .none,
                                      cpuStrain: .none, headline: "Fixture", culprits: [], also: [])
        let recorder = PulseRecorder(queue: queue, readHistory: { [] }, readDiagnosis: {
            entered.fulfill(); _ = release.wait(timeout: .now() + 10)
            return (found, [])
        })
        recorder.start(); await drain(queue)
        recorder.diagnoseFresh(onSkipped: { skipped.fulfill() }) { _, _ in
            XCTFail("Retired diagnosis must not dispatch a process action")
        }
        await fulfillment(of: [entered], timeout: 2)
        recorder.beginStopping(); release.signal()
        await recorder.stop(); await drain(queue)
        await fulfillment(of: [skipped], timeout: 2)
        XCTAssertNil(recorder.diagnosis)
    }
    func testColdManualRequestsNeverReadAndFreshRequestReleasesCaller() async {
        let queue = DispatchQueue(label: "thermo-cold-manual-diagnosis")
        let skipped = expectation(description: "cold request skipped")
        let recorder = PulseRecorder(queue: queue, samplingAllowed: { false }, readDiagnosis: {
            XCTFail("Cold disabled recorder must not read process inventory")
            let system = SlowdownSystem(memoryBytes: 0, swapUsed: 0, swapTotal: 0,
                                        pressure: .normal, load1: 0, cores: 1)
            return (SlowdownDiagnosis(sampled: Date(), system: system, memoryStrain: .none,
                                     cpuStrain: .none, headline: "Unused", culprits: [], also: []), [])
        })
        recorder.diagnoseNow()
        recorder.diagnoseFresh(onSkipped: { skipped.fulfill() }) { _, _ in XCTFail("Cold request cannot dispatch an action") }
        await drain(queue); await fulfillment(of: [skipped], timeout: 2)
        XCTAssertNil(recorder.diagnosis)
    }

}
