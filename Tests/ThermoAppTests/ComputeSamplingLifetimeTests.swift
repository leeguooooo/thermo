import Combine
import XCTest
@testable import CleanKit
@testable import ThermoApp

final class ComputeSamplingLifetimeTests: XCTestCase {
    @MainActor func testReplacementVisibilityLeaseSurvivesOldPageDisappearing() async {
        let reader = Reader()
        defer { reader.release.signal() }
        let model = ComputeModel(readSample: { reader.read($0) }, refreshInterval: 60)
        defer { model.stop() }
        let old = UUID(), replacement = UUID()
        model.setVisible(true, owner: old)
        await fulfillment(of: [reader.began], timeout: 3)
        model.setVisible(true, owner: replacement)
        model.setVisible(false, owner: old)
        XCTAssertTrue(model.samplingActive)
        XCTAssertFalse(reader.cancelled)
        model.setVisible(false, owner: replacement)
        XCTAssertFalse(model.samplingActive)
        XCTAssertTrue(reader.cancelled)
        reader.release.signal()
        for _ in 0..<100 where model.sampleInFlight { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(model.current)
        XCTAssertEqual(reader.count, 1)
    }

    private final class Reader: @unchecked Sendable {
        let began = XCTestExpectation(description: "old computation blocked")
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var calls = 0
        private var token: ScanCancellation?
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return token?.isCancelled == true }
        func read(_ cancellation: ScanCancellation) -> ComputeActivity {
            lock.lock(); calls += 1; let call = calls
            if call == 1 { token = cancellation }
            lock.unlock()
            if call == 1 { began.fulfill(); _ = release.wait(timeout: .now() + 15) }
            return .init(sampled: Date(), cpu: Double(call), cores: 8, devices: [], programs: [])
        }
    }

    @MainActor func testReopenDrainsOldWorkThenImmediatelyRequestsFreshReading() async {
        let reader = Reader()
        defer { reader.release.signal() }
        let model = ComputeModel(readSample: { reader.read($0) }, refreshInterval: 60)
        defer { model.stop() }
        var seen: [Double] = []
        let fresh = expectation(description: "reopened session published immediately after drain")
        let observation = model.$current.compactMap { $0?.cpu }.sink { cpu in
            seen.append(cpu)
            if cpu == 2 { model.stop(); fresh.fulfill() }
        }
        model.start()
        await fulfillment(of: [reader.began], timeout: 3)
        model.stop()
        XCTAssertTrue(reader.cancelled)
        model.start()
        XCTAssertEqual(reader.count, 1)
        reader.release.signal()
        // The timer is held at a minute; only completion can trigger this new reading.
        await fulfillment(of: [fresh], timeout: 15)
        XCTAssertEqual(seen, [2])
        XCTAssertEqual(reader.count, 2)
        XCTAssertFalse(model.sampleInFlight)
        withExtendedLifetime(observation) {}
    }

    @MainActor func testCloseBeforeQueuedWorkStartsSkipsThePhysicalReader() async {
        let queue = DispatchQueue(label: "test.compute.queued")
        queue.suspend()
        let reader = Reader()
        defer { reader.release.signal() }
        let model = ComputeModel(readSample: { reader.read($0) }, samplingQueue: queue)
        model.start(); model.stop()
        let drained = expectation(description: "worker and publication handled")
        queue.async { DispatchQueue.main.async { drained.fulfill() } }
        queue.resume()
        await fulfillment(of: [drained], timeout: 3)
        XCTAssertEqual(reader.count, 0)
        XCTAssertNil(model.current)
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertFalse(model.sampleInFlight)
    }
}
