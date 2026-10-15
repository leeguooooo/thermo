@testable import CleanKit
@testable import ThermoApp
import XCTest

final class NativeUpdatesModelTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var maximum = 0
        func start() { lock.lock(); active += 1; maximum = max(maximum, active); lock.unlock() }
        func stop() { lock.lock(); active -= 1; lock.unlock() }
        var remaining: Int { lock.lock(); defer { lock.unlock() }; return active }
    }

    @MainActor
    func testAtMostFourChecksAndRetirementDiscardsCancelledResults() async throws {
        let sources = (0..<6).map { i in
            NativeUpdateSource(app: InstalledApp(path: "/fixture/\(i).app", name: "Fixture \(i)", bundleID: "com.example.fixture\(i)"), kind: "sparkle")
        }
        let counter = Counter()
        let started = expectation(description: "four checks started"); started.expectedFulfillmentCount = 4
        let model = NativeUpdatesModel(read: { _ in sources }, checker: { source in
            counter.start(); started.fulfill()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            counter.stop()
            return NativeUpdateCheck(source: source, status: "cancelled", message: "fixture stopped")
        })
        model.load()
        for _ in 0..<100 where model.loading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.sources.count, 6)
        model.checkAll(sources)
        XCTAssertEqual(model.checking.count, 4)
        await fulfillment(of: [started], timeout: 5)
        model.retire()
        for _ in 0..<100 where !model.checking.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.checking.isEmpty)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(counter.remaining, 0)
        XCTAssertLessThanOrEqual(counter.maximum, 4)
    }

    @MainActor
    func testQueuedBatchFinishesEveryDistinctSource() async throws {
        let sources = (0..<7).map { i in
            NativeUpdateSource(app: InstalledApp(path: "/fixture/\(i).app", name: "Fixture \(i)", bundleID: "com.example.fixture\(i)"), kind: "sparkle")
        }
        let counter = Counter()
        let all = expectation(description: "every source checked"); all.expectedFulfillmentCount = sources.count
        let model = NativeUpdatesModel(read: { _ in sources }, checker: { source in
            counter.start()
            try? await Task.sleep(nanoseconds: 10_000_000)
            counter.stop(); all.fulfill()
            return NativeUpdateCheck(source: source, status: "noNewerCompatibleVersion", message: "fixture")
        })
        model.load()
        for _ in 0..<100 where model.loading { try await Task.sleep(nanoseconds: 10_000_000) }
        model.checkAll(sources + sources)
        await fulfillment(of: [all], timeout: 5)
        for _ in 0..<100 where model.results.count < sources.count { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.results.count, sources.count)
        XCTAssertTrue(model.checking.isEmpty)
        XCTAssertLessThanOrEqual(counter.maximum, 4)
        model.retire()
    }

    @MainActor
    func testStopAllKeepsFinishedResultsAndDropsPendingWork() async throws {
        let sources = (0..<6).map { i in
            NativeUpdateSource(app: InstalledApp(path: "/fixture/\(i).app", name: "Fixture \(i)", bundleID: "com.example.fixture\(i)"), kind: "sparkle")
        }
        let began = expectation(description: "four slow checks running"); began.expectedFulfillmentCount = 4
        let model = NativeUpdatesModel(read: { _ in sources }, checker: { source in
            if source.id == sources[0].id { return NativeUpdateCheck(source: source, status: "noNewerCompatibleVersion", message: "finished") }
            began.fulfill()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            // Even an uncooperative checker returning a result after cancellation must not publish it as available.
            return NativeUpdateCheck(source: source, status: "available", message: "too late")
        })
        model.load()
        for _ in 0..<100 where model.loading { try await Task.sleep(nanoseconds: 10_000_000) }
        model.check(sources[0])
        for _ in 0..<100 where model.results[sources[0].id] == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        model.checkAll(Array(sources.dropFirst()))
        await fulfillment(of: [began], timeout: 5)
        model.stopAll()
        for _ in 0..<100 where !model.checking.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.results[sources[0].id]?.status, "noNewerCompatibleVersion")
        XCTAssertEqual(model.results.values.filter { $0.status == "cancelled" }.count, 4)
        XCTAssertNil(model.results[sources[5].id])
        model.retire()
    }
}
