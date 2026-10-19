import XCTest
@testable import CleanKit
@testable import ThermoApp

final class MemorySamplingCancellationTests: XCTestCase {
    private final class Reader: @unchecked Sendable {
        let started = XCTestExpectation(description: "first inventory held")
        let restarted = XCTestExpectation(description: "fresh inventory requested")
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var calls = 0
        var firstToken: ScanCancellation?
        let fresh = Date()
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return firstToken?.isCancelled == true }
        func read(_ token: ScanCancellation) -> MemoryModel.Reading {
            lock.lock(); calls += 1; let index = calls
            if index == 1 { firstToken = token }
            lock.unlock()
            if index == 1 {
                started.fulfill()
                _ = release.wait(timeout: .now() + 10)
            } else { restarted.fulfill() }
            return .init(breakdown: nil,
                         inventory: .init(sampled: index == 1 ? .distantPast : fresh,
                                          programs: [], processCount: 0, unreadableCount: 0, available: true), history: [])
        }
    }

    @MainActor func testCloseCancelsAndReopenWaitsForThePhysicalReadBeforeRestarting() async throws {
        let reader = Reader()
        defer { reader.release.signal() }
        let model = MemoryModel(read: { reader.read($0) }, readDay: { [] })
        defer { model.stop() }
        model.start()
        await fulfillment(of: [reader.started], timeout: 3)
        model.stop()
        XCTAssertTrue(reader.cancelled)
        for _ in 0..<10 { model.start(); model.stop() }
        model.start()
        XCTAssertEqual(reader.count, 1)
        XCTAssertTrue(model.sampleInFlight)
        XCTAssertNil(model.sampled)
        reader.release.signal()
        await fulfillment(of: [reader.restarted], timeout: 3)
        for _ in 0..<100 where model.sampleInFlight { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(reader.count, 2)
        XCTAssertEqual(model.sampled, reader.fresh)
        XCTAssertTrue(model.inventoryAvailable)
        XCTAssertFalse(model.sampleInFlight)
    }
}
