import XCTest
@testable import CleanKit
@testable import ThermoApp

final class SpaceOverviewLifecycleTests: XCTestCase {
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
}
