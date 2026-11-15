import XCTest
import ThermoL10n
import CleanKit
@testable import DiskFeature

final class DiskPresentationTests:XCTestCase {
    @MainActor func testDiskRefreshRetainsPreviousLocationsAndReplacesUpdatedOnes() {
        let old = [SpaceOverview.Entry(id: "a", title: "A", bytes: 100, children: []),
                   SpaceOverview.Entry(id: "b", title: "B", bytes: 200, children: [])]
        let update = SpaceOverview.Entry(id: "a", title: "A", bytes: 300, children: [])
        let merged = SpaceOverviewModel.merging(old, updates: [update])
        XCTAssertEqual(merged.map(\.id), ["a", "b"])
        XCTAssertEqual(merged.map(\.bytes), [300, 200])
    }
    @MainActor func testLanguageSwitchRelocalizesDiskTitlesWithoutRescanning() {
        L10n.override = .english
        defer { L10n.override = nil }
        var overview = SpaceOverview(capacity: 100, free: 25, purgeable: 0,
                                     entries: [.init(id: "apps", title: "Applications", bytes: 10, children: [])], duration: 1)
        overview.language = "en"
        let model = SpaceOverviewModel(cached: (overview, Date()))
        XCTAssertEqual(model.entries.count, 1)
        L10n.override = .simplifiedChinese
        model.discardIncompatibleResults()
        XCTAssertEqual(model.entries.first?.title, tr("Applications"))
        XCTAssertEqual(model.entries.first?.bytes, 10)
        XCTAssertEqual(model.overview?.language, "zh-Hans")
        XCTAssertNotNil(model.measuredAt)
        XCTAssertFalse(model.measuring)
    }
}
