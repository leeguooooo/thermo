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
        let model = MemoryModel(read: { reader.read($0) }, readHistory: { _ in [] }, readDay: { [] })
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
    private final class HistoryReader: @unchecked Sendable {
        let began = XCTestExpectation(description: "historical read held after current inventory published")
        let restarted = XCTestExpectation(description: "new session history requested")
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var inventories = 0
        private var histories = 0
        let now = Date()
        var inventoryCount: Int { lock.lock(); defer { lock.unlock() }; return inventories }
        func inventory() -> MemoryModel.Reading {
            lock.lock(); inventories += 1; lock.unlock()
            return .init(breakdown: nil, inventory: .init(sampled: now, programs: [], processCount: 0,
                                                        unreadableCount: 0, available: true), history: [])
        }
        func history() -> [ProgramMemoryRecord] {
            lock.lock(); histories += 1; let call = histories; lock.unlock()
            if call == 1 { began.fulfill(); _ = release.wait(timeout: .now() + 10) }
            else { restarted.fulfill() }
            let id = call == 1 ? "obsolete-session" : "current-session"
            return [.init(t: now.addingTimeInterval(-60), programs: [id: 123], names: [id: id])]
        }
    }

    @MainActor func testCurrentInventoryPublishesBeforeHistoryAndReopenDiscardsOldHistory() async throws {
        let reader = HistoryReader()
        defer { reader.release.signal() }
        let model = MemoryModel(read: { _ in reader.inventory() },
                                readHistory: { _ in reader.history() }, readDay: { [] })
        defer { model.stop() }
        model.start()
        await fulfillment(of: [reader.began], timeout: 3)
        // The file read is still blocked, while current data is already usable.
        XCTAssertEqual(model.sampled, reader.now)
        XCTAssertTrue(model.inventoryAvailable)
        XCTAssertTrue(model.sampleInFlight)
        XCTAssertFalse(model.programReadings.contains { $0.programs["obsolete-session"] != nil })
        model.stop()
        model.start()
        XCTAssertEqual(reader.inventoryCount, 1, "reopen must wait for the old physical history read")
        reader.release.signal()
        await fulfillment(of: [reader.restarted], timeout: 3)
        for _ in 0..<200 where model.sampleInFlight { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.sampleInFlight)
        XCTAssertEqual(reader.inventoryCount, 2)
        XCTAssertTrue(model.programReadings.contains { $0.programs["current-session"] != nil })
        XCTAssertFalse(model.programReadings.contains { $0.programs["obsolete-session"] != nil })
        model.stop()
        model.sample() // A delayed action callback after the page disappeared.
        XCTAssertFalse(model.sampleInFlight)
        XCTAssertEqual(reader.inventoryCount, 2)
    }

}
