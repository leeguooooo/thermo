import Combine
import Foundation
import XCTest
@testable import CleanKit
@testable import ThermoApp

final class PulseSamplingLifetimeTests: XCTestCase {
    final class Reader: @unchecked Sendable {
        let entered: XCTestExpectation
        let release = DispatchSemaphore(value: 0)
        let returned: XCTestExpectation
        let lock = NSLock()
        var count = 0
        init(entered: XCTestExpectation, returned: XCTestExpectation) {
            self.entered = entered; self.returned = returned
        }
        func sample() -> MachinePulse {
            lock.lock(); count += 1; let index = count; lock.unlock()
            if index == 1 { entered.fulfill(); release.wait(); returned.fulfill() }
            return MachinePulse(load1: Double(index), load5: 0, cores: 8, thermal: .nominal,
                                memory: .normal, swapUsedMB: 0, hogs: [], sampled: Date())
        }
    }

    /// The worker enqueues publication before this fence, so its main-queue receipt
    /// proves the old result was handled. A short inverted wait cannot prove that.
    @MainActor private func drain(_ queue: DispatchQueue, returned: XCTestExpectation) async {
        let drained = expectation(description: "worker and main publication queues drained")
        queue.async { DispatchQueue.main.async { drained.fulfill() } }
        await fulfillment(of: [returned, drained], timeout: 15)
    }

    @MainActor func testFinishingAfterLastReleaseCannotPublish() async {
        let entered = expectation(description: "first read blocked"), returned = expectation(description: "read returned")
        let reader = Reader(entered: entered, returned: returned)
        defer { reader.release.signal() }
        let queue = DispatchQueue(label: "test.pulse.close", qos: .utility)
        let model = SystemPulse(readSample: { reader.sample() }, samplingQueue: queue)
        var published: [Double] = []
        let observation = model.$current.compactMap { $0 }.sink { published.append($0.load1) }
        model.hold(); model.hold(); await fulfillment(of: [entered], timeout: 1)
        model.release(); XCTAssertTrue(model.samplingActive); XCTAssertEqual(model.holderCount, 1)
        model.release(); XCTAssertFalse(model.samplingActive); XCTAssertEqual(model.holderCount, 0)
        reader.release.signal()
        await drain(queue, returned: returned)
        XCTAssertTrue(published.isEmpty)
        XCTAssertNil(model.current)
        withExtendedLifetime(observation) {}
    }

    @MainActor func testReopeningRejectsPreviousReadAndPublishesTheNewSession() async {
        let entered = expectation(description: "old read blocked"), returned = expectation(description: "old read returned")
        let reader = Reader(entered: entered, returned: returned)
        defer { reader.release.signal() }
        let queue = DispatchQueue(label: "test.pulse.reopen", qos: .utility)
        let model = SystemPulse(readSample: { reader.sample() }, samplingQueue: queue)
        var loads: [Double] = []
        let fresh = expectation(description: "new session published")
        let observation = model.$current.compactMap { $0 }.sink { value in
            loads.append(value.load1)
            if value.load1 == 2 { model.release(); fresh.fulfill() }
        }
        model.hold(); await fulfillment(of: [entered], timeout: 1)
        model.release(); model.hold(); reader.release.signal()
        await fulfillment(of: [fresh], timeout: 15)
        await drain(queue, returned: returned)
        XCTAssertEqual(loads, [2]); XCTAssertEqual(model.current?.load1, 2)
        XCTAssertFalse(model.samplingActive)
        withExtendedLifetime(observation) {}
    }
}

extension PulseSamplingLifetimeTests {
    @MainActor func testRetirementWaitsForDelayedActionReviewAndItsJournalWrite() async {
        let queue = DispatchQueue(label: "test.pulse.action-review")
        let readEntered = expectation(description: "follow-up reader entered")
        let recordEntered = expectation(description: "journal write entered")
        let finished = expectation(description: "retirement returned")
        let releaseRead = DispatchSemaphore(value: 0), releaseRecord = DispatchSemaphore(value: 0)
        defer { releaseRead.signal(); releaseRecord.signal() }
        let before = MachinePulse(load1: 1, load5: 1, cores: 8, thermal: .nominal,
                                  memory: .normal, swapUsedMB: 0, hogs: [], sampled: Date())
        let hog = MachinePulse.Hog(id: "com.example.review", name: "Review fixture", cpu: 0,
                                   memoryKB: 100, pids: [], app: nil, quittable: false)
        let model = SystemPulse(samplingQueue: queue, reviewDelay: 0.1, readActionReview: { target, baseline, action in
            readEntered.fulfill(); _ = releaseRead.wait(timeout: .now() + 10)
            return PulseActionReview(action: action, target: target, before: baseline, after: baseline,
                                     afterTarget: nil, inventoryAvailable: false)
        }, recordActionReview: { _ in
            recordEntered.fulfill(); _ = releaseRecord.wait(timeout: .now() + 10)
        })
        // Exercise the same promised follow-up path after restart completion, with no OS action.
        model.review(hog, before: before, action: .restart)
        model.stop()
        var retired = false
        let retirement = Task { await model.finishStoppingFeature(); retired = true; finished.fulfill() }
        retirement.cancel() // Cancellation cannot release physical ownership or spin on the main actor.
        let fence = expectation(description: "ordinary queue fence passed before delayed read")
        queue.async { DispatchQueue.main.async { fence.fulfill() } }
        await fulfillment(of: [fence, readEntered], timeout: 2)
        XCTAssertFalse(retired, "An ordinary queue fence must not finish retirement while a promised review is pending")
        releaseRead.signal()
        await fulfillment(of: [recordEntered], timeout: 2)
        XCTAssertFalse(retired, "Retirement must include the real journal write, not just the read")
        releaseRecord.signal()
        await fulfillment(of: [finished], timeout: 2)
        await retirement.value
        XCTAssertNotNil(model.actionFeedback)
        XCTAssertNil(model.current)
    }
}
