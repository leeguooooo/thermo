import XCTest
@testable import CleanKit
@testable import ThermoApp

final class SpaceOverviewLifecycleTests: XCTestCase {
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
