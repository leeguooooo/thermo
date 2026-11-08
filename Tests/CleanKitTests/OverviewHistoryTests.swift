import XCTest
@testable import CleanKit

final class OverviewHistoryTests: XCTestCase {
    func file() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func overview(free: Int64, downloads: Int64, apps: Int64) -> SpaceOverview {
        let child = SpaceOverview.Entry(id: "dl", title: "Downloads", path: "/Users/x/Downloads", bytes: downloads, children: [], note: nil, complete: true)
        let home = SpaceOverview.Entry(id: "home", title: "Other folders in your home", path: nil, bytes: downloads + 5_000_000_000, children: [child], note: nil, complete: true)
        let a = SpaceOverview.Entry(id: "apps", title: "Applications", path: "/Applications", bytes: apps, children: [], note: nil, complete: true)
        return SpaceOverview(capacity: 1_000_000_000_000, free: free, purgeable: 0, entries: [home, a], duration: 1)
    }

    func testListsTheFolderThatGrewSinceAMeasurementHalfADayOld() throws {
        let url = file(); let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(OverviewHistory.record(overview(free: 30_000_000_000, downloads: 52_000_000_000, apps: 60_000_000_000), at: t0, to: url), "nothing to compare with yet")
        XCTAssertNil(OverviewHistory.record(overview(free: 25_000_000_000, downloads: 57_000_000_000, apps: 60_000_000_000), at: t0 + 3_600 * 2, to: url),
                     "two hours is too soon to call it growth")
        let growth = try XCTUnwrap(OverviewHistory.record(overview(free: 3_000_000_000, downloads: 74_000_000_000, apps: 60_500_000_000), at: t0 + 86_400, to: url))
        XCTAssertEqual(growth.items.map(\.path), ["/Users/x/Downloads"], "the folder explains it; the heading and sub-1 GB changes are left out")
        XCTAssertEqual(growth.items.first?.changeBytes, 22_000_000_000, "compared with the snapshot closest to a day old")
        XCTAssertEqual(growth.freeDropBytes, 27_000_000_000)
        XCTAssertEqual(growth.since, t0)
    }

    func testKeepsOneSnapshotPerHourAndDropsOldOnes() {
        let url = file(); let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        OverviewHistory.record(overview(free: 1, downloads: 1, apps: 1), at: t0, to: url)
        OverviewHistory.record(overview(free: 1, downloads: 1, apps: 1), at: t0 + 600, to: url)
        XCTAssertEqual(OverviewHistory.read(url).count, 1)
        OverviewHistory.record(overview(free: 1, downloads: 1, apps: 1), at: t0 + 15 * 86_400, to: url)
        XCTAssertEqual(OverviewHistory.read(url).map(\.at), [t0 + 15 * 86_400])
    }

    func testStoppedMeasurementsAreNotRecorded() {
        let url = file()
        var o = overview(free: 1, downloads: 1, apps: 1); o.cancelled = true; o.sizeVersion = 1
        o.noteGrowth(history: url)
        XCTAssertTrue(OverviewHistory.read(url).isEmpty)
    }
}
