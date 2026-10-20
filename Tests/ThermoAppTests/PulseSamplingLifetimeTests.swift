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
