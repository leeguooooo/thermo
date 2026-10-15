import XCTest
@testable import CleanKit

final class OverviewSchedulingTests: XCTestCase {
    var home = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: home + "/apps/fast", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/apps/slow", withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: home) }
    var spot: SpaceOverview.Spot { .init(id: "fixture", title: "Fixture", paths: [home + "/apps"], children: 5) }
    func testFastSiblingPublishesBeforeSlowSiblingAndCancelledBytesAreExcluded() throws {
        let token = ScanCancellation()
        let lock = NSLock()
        var updates: [SpaceOverview.Entry] = []
        let result = SpaceOverview.measure(home: home, spots: [spot], onEntry: { entry in
            lock.lock(); updates.append(entry); lock.unlock()
            if entry.complete == false { token.cancel() }
        }, cancellation: token, footprint: { path, cancellation in
            if path.hasSuffix("/slow") {
                let until = Date().addingTimeInterval(2)
                while !cancellation.isCancelled && Date() < until { Thread.sleep(forTimeInterval: 0.001) }
                return DiskFootprint(allocated: 999_999, files: 999, newest: nil, denied: false)
            }
            return DiskFootprint(allocated: 100, files: 1, newest: nil, denied: false)
        })
        let group = try XCTUnwrap(result.entries.first { $0.id == "fixture" })
        XCTAssertTrue(result.cancelled == true)
        XCTAssertEqual(group.complete, false)
        XCTAssertEqual(group.bytes, 100, "interrupted measurements must not enter the total")
        XCTAssertEqual(group.measuredLocations, 1)
        XCTAssertEqual(group.totalLocations, 2)
        XCTAssertEqual(group.children.map(\.path), [home + "/apps/fast"])
        XCTAssertEqual(updates.last?.bytes, 100)
    }
    func testCompleteCategoryUpdateFollowsPartialUpdate() throws {
        var updates: [SpaceOverview.Entry] = []
        let result = SpaceOverview.measure(home: home, spots: [spot], onEntry: { updates.append($0) },
                                          footprint: { _, _ in DiskFootprint(allocated: 100, files: 1, newest: nil, denied: false) })
        let categoryUpdates = updates.filter { $0.id == "fixture" }
        XCTAssertEqual(categoryUpdates.map(\.measuredLocations), [1, 2])
        XCTAssertEqual(categoryUpdates.map(\.complete), [false, true])
        let group = try XCTUnwrap(result.entries.first { $0.id == "fixture" })
        XCTAssertEqual(group.bytes, 200)
        XCTAssertEqual(group.complete, true)
    }
    func testIncompleteCategoryCannotReplaceCompleteOverviewCache() throws {
        let url = URL(fileURLWithPath: home + "/overview.json")
        var full = SpaceOverview(capacity: 1000, free: 100, purgeable: 0, entries: [], duration: 1)
        full.measuredAt = Date(timeIntervalSince1970: 100); full.language = "en"
        full.sizeVersion = 1
        L10n.override = .english
        defer { L10n.override = nil }
        full.save(to: url)
        var partial = full
        partial.entries = [.init(id: "fixture", title: "Fixture", bytes: 100, children: [], complete: false,
                                 measuredLocations: 1, totalLocations: 2)]
        partial.save(to: url)
        XCTAssertEqual(SpaceOverview.cached(from: url, now: Date(timeIntervalSince1970: 200))?.0.entries.count, 0)
    }

    func testConcurrentMeasurementsSharePhysicalWorkerSlotsAfterCancellation() async throws {
        let count = SpaceOverview.measurementConcurrency
        let paths = try (0..<count).map { i -> String in
            let path = home + "/held-\(i)"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        }
        let spot = SpaceOverview.Spot(id: "held", title: "Held", paths: paths, children: 0)
        let first = ScanCancellation(), second = ScanCancellation()
        let held = expectation(description: "all physical slots held"); held.expectedFulfillmentCount = count
        let entered = expectation(description: "second caller entered")
        let unexpected = expectation(description: "no extra physical slots"); unexpected.isInverted = true
        let finished = expectation(description: "both measurements finished"); finished.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        defer { first.cancel(); second.cancel(); for _ in 0..<count { release.signal() } }
        let home = home
        DispatchQueue.global().async {
            _ = SpaceOverview.measure(home: home, spots: [spot], cancellation: first, footprint: { _, _ in
                held.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return DiskFootprint(allocated: 1, files: 1, newest: nil, denied: false)
            })
            finished.fulfill()
        }
        await fulfillment(of: [held], timeout: 5)
        first.cancel()
        DispatchQueue.global().async {
            entered.fulfill()
            _ = SpaceOverview.measure(home: home, spots: [spot], cancellation: second, footprint: { _, _ in
                unexpected.fulfill()
                return DiskFootprint(allocated: 1, files: 1, newest: nil, denied: false)
            })
            finished.fulfill()
        }
        await fulfillment(of: [entered], timeout: 5)
        await fulfillment(of: [unexpected], timeout: 0.15)
        second.cancel()
        for _ in 0..<count { release.signal() }
        await fulfillment(of: [finished], timeout: 5)
    }
}
