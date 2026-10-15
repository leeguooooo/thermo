import XCTest
@testable import CleanKit
@testable import ThermoApp

final class SpaceOverviewLifecycleTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var saved: [String] = []
        func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
        func save(_ id: String) { lock.lock(); saved.append(id); lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        var writes: [String] { lock.lock(); defer { lock.unlock() }; return saved }
    }

    @MainActor
    func testCleanupInvalidationWaitsForOldWorkerAndOnlySavesTheRequestedReplacement() async throws {
        let calls = Calls()
        let began = expectation(description: "old measurement held")
        let restarted = expectation(description: "replacement started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = SpaceOverviewModel(cached: nil, diskSpace: nil, read: { token, publish in
            let n = calls.next()
            let entry = SpaceOverview.Entry(id: "run-\(n)", title: "Fixture", bytes: Int64(n), children: [], complete: true)
            publish?(entry)
            if n == 1 {
                began.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            } else { restarted.fulfill() }
            var overview = SpaceOverview(capacity: 100, free: 10, purgeable: 0, entries: [entry], duration: 1)
            overview.cancelled = token.isCancelled
            overview.measuredAt = Date(); overview.language = L10n.current.rawValue; overview.sizeVersion = 1
            return overview
        }, save: { calls.save($0.entries.first?.id ?? "missing") }, readDiskSpace: { nil })
        model.measure()
        await fulfillment(of: [began], timeout: 5)
        model.invalidateAfterCleanup()
        XCTAssertTrue(model.measuring)
        XCTAssertTrue(model.stopping)
        for _ in 0..<20 { model.measure() }
        model.measureIfStale()
        XCTAssertEqual(calls.value, 1, "invalidation must not release an occupied worker")
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(calls.writes.isEmpty)
        release.signal()
        await fulfillment(of: [restarted], timeout: 5)
        for _ in 0..<100 where model.measuring { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.measuring)
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(calls.writes, ["run-2"])
        XCTAssertEqual(model.overview?.entries.first?.id, "run-2")
    }

    func testOverviewCleanupRoutesScanTheRelevantCategory() {
        XCTAssertEqual(DiskOverviewView.cleanupRoute(for: "projects")?.category, .projects)
        XCTAssertEqual(DiskOverviewView.cleanupRoute(for: "simulator-runtimes")?.category, .xcode)
        XCTAssertEqual(DiskOverviewView.cleanupRoute(for: "homebrew")?.category, .devCaches)
        XCTAssertNil(DiskOverviewView.cleanupRoute(for: "apps"), "installed applications are not disposable cache")
        XCTAssertNil(DiskOverviewView.cleanupRoute(for: "app-data"), "active application data must not be suggested as generic garbage")
    }

    @MainActor
    func testStreamKeepsOnlyLatestCategoryAndCannotRegressAfterCompletion() {
        let model = SpaceOverviewModel(cached: nil, diskSpace: nil)
        let first = SpaceOverview.Entry(id: "apps", title: "Apps", bytes: 100, children: [], complete: false,
                                        measuredLocations: 1, totalLocations: 2)
        let done = SpaceOverview.Entry(id: "apps", title: "Apps", bytes: 200, children: [], complete: true,
                                       measuredLocations: 2, totalLocations: 2)
        model.acceptEntry(first)
        model.acceptEntry(done)
        model.acceptEntry(first)
        XCTAssertEqual(model.partial.count, 1)
        XCTAssertEqual(model.partial[0].bytes, 200)
        XCTAssertEqual(model.partial[0].complete, true)
    }

    @MainActor
    func testCapacityIsAvailableBeforeFolderMeasurementAndCleanupDropsOldBreakdown() {
        let live = DiskSpaceSnapshot(volumeID: "fixture", capacityBytes: 1000, availableBytes: 100,
                                     measuredAt: Date(timeIntervalSince1970: 200))
        var old = SpaceOverview(capacity: 1000, free: 50, purgeable: 0, entries: [], duration: 1)
        old.measuredAt = Date(timeIntervalSince1970: 100)
        let model = SpaceOverviewModel(cached: (old, old.measuredAt!), diskSpace: live)
        XCTAssertEqual(model.diskSpace?.availableBytes, 100)
        XCTAssertFalse(model.measuring, "capacity does not require walking folders")
        XCTAssertNotNil(model.overview)
        model.invalidateAfterCleanup()
        XCTAssertNil(model.overview)
        XCTAssertNil(model.measuredAt)
        XCTAssertTrue(model.partial.isEmpty)
        XCTAssertFalse(model.stopped, "next open may refresh instead of showing old results as stopped")
        XCTAssertNotNil(model.diskSpace)
    }

    @MainActor
    func testIncompleteUpdatesUseAttemptsToRejectOlderResultsWithTheSameMeasuredCount() {
        let model = SpaceOverviewModel(cached: nil, diskSpace: nil)
        let old = SpaceOverview.Entry(id: "apps", title: "Apps", bytes: 10, children: [], complete: false,
                                       measuredLocations: 0, totalLocations: 2, attemptedLocations: 1, sizeState: .incomplete)
        var latest = old; latest.bytes = 20; latest.attemptedLocations = 2
        model.acceptEntry(old)
        model.acceptEntry(latest)
        model.acceptEntry(old)
        XCTAssertEqual(model.partial.first?.bytes, 20)
        XCTAssertEqual(model.partial.first?.attemptedLocations, 2)
    }
}
