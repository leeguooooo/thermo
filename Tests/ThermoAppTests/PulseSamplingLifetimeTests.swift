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
            if index == 1 { entered.fulfill(); _ = release.wait(timeout: .now() + 3); returned.fulfill() }
            return MachinePulse(load1: Double(index), load5: 0, cores: 8, thermal: .nominal,
                                memory: .normal, swapUsedMB: 0, hogs: [], sampled: Date())
        }
    }

    @MainActor func testFinishingAfterLastReleaseCannotPublish() async {
        let entered = expectation(description: "first read blocked"), returned = expectation(description: "read returned")
        let reader = Reader(entered: entered, returned: returned)
        let model = SystemPulse(readSample: { reader.sample() })
        let unexpected = expectation(description: "closed view must not publish")
        unexpected.isInverted = true
        let observation = model.$current.compactMap { $0 }.sink { _ in unexpected.fulfill() }
        model.hold(); model.hold(); await fulfillment(of: [entered], timeout: 1)
        model.release(); XCTAssertTrue(model.samplingActive); XCTAssertEqual(model.holderCount, 1)
        model.release(); XCTAssertFalse(model.samplingActive); XCTAssertEqual(model.holderCount, 0)
        reader.release.signal()
        await fulfillment(of: [returned, unexpected], timeout: 0.2)
        XCTAssertNil(model.current)
        withExtendedLifetime(observation) {}
    }

    @MainActor func testReopeningRejectsPreviousReadAndPublishesTheNewSession() async {
        let entered = expectation(description: "old read blocked"), returned = expectation(description: "old read returned")
        let reader = Reader(entered: entered, returned: returned)
        let model = SystemPulse(readSample: { reader.sample() })
        var loads: [Double] = []
        let fresh = expectation(description: "new session published")
        let observation = model.$current.compactMap { $0 }.sink { value in
            loads.append(value.load1)
            if value.load1 == 2 { fresh.fulfill() }
        }
        model.hold(); await fulfillment(of: [entered], timeout: 1)
        model.release(); model.hold(); reader.release.signal()
        await fulfillment(of: [returned, fresh], timeout: 1)
        XCTAssertEqual(loads, [2]); XCTAssertEqual(model.current?.load1, 2)
        model.release(); XCTAssertFalse(model.samplingActive)
        withExtendedLifetime(observation) {}
    }
}
