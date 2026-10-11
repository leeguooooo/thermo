import XCTest
@testable import CleanKit

final class SpaceCacheTests: XCTestCase {
    override func setUp() { L10n.override = .english }
    override func tearDown() { L10n.override = nil }

    func fixture() -> SpaceOverview {
        var overview = SpaceOverview(capacity: 100, free: 25, purgeable: 5, entries: [], duration: 10)
        overview.measuredAt = Date(timeIntervalSince1970: 100)
        overview.language = "en"
        return overview
    }

    func testCacheUsesMeasurementTimeRatherThanFileModificationTime() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        fixture().save(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 190)], ofItemAtPath: url.path)
        let cache = try XCTUnwrap(SpaceOverview.cached(from: url, now: Date(timeIntervalSince1970: 200)))
        XCTAssertEqual(cache.1, Date(timeIntervalSince1970: 100))
    }

    func testCacheRejectsPartialFutureAndWrongLanguageResults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var cancelled = fixture(); cancelled.cancelled = true
        var future = fixture(); future.measuredAt = Date(timeIntervalSince1970: 300)
        var translated = fixture(); translated.language = "zh-Hans"
        var legacy = fixture(); legacy.measuredAt = nil; legacy.language = nil
        for overview in [cancelled, future, translated, legacy] {
            try JSONEncoder().encode(overview).write(to: url)
            XCTAssertNil(SpaceOverview.cached(from: url, now: Date(timeIntervalSince1970: 200)))
        }
    }

    func testCleanupInvalidationRejectsLateResultsAndAllowsNewMeasurement() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent("Library/Caches/dev.thermo/space-overview.json")
        let old = fixture()
        old.save(to: url)
        SpaceOverview.invalidate(home: home.path, now: Date(timeIntervalSince1970: 200))
        old.save(to: url)
        XCTAssertNil(SpaceOverview.cached(from: url, now: Date(timeIntervalSince1970: 300)),
                     "late callbacks must not resurrect a pre-cleanup measurement")
        var fresh = fixture(); fresh.measuredAt = Date(timeIntervalSince1970: 250)
        fresh.save(to: url)
        XCTAssertNotNil(SpaceOverview.cached(from: url, now: Date(timeIntervalSince1970: 300)))
        // Even an older process ignoring the marker cannot make an old file valid.
        try JSONEncoder().encode(old).write(to: url)
        XCTAssertNil(SpaceOverview.cached(from: url, now: Date(timeIntervalSince1970: 300)))
    }

    func testKnownHeadingsRelocalizeWithoutRenewingMeasurementOrChangingPaths() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var overview = fixture()
        overview.entries = [.init(id: "apps", title: "Applications", bytes: 10,
                                  children: [.init(id: "/fixture/app", title: "User Named App", path: "/fixture/app", bytes: 10, children: [])])]
        overview.save(to: url)
        L10n.override = .simplifiedChinese
        let cached = try XCTUnwrap(SpaceOverview.cached(from: url, now: Date(timeIntervalSince1970: 200), localize: true))
        XCTAssertEqual(cached.1, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(cached.0.entries.first?.title, tr("Applications"))
        XCTAssertEqual(cached.0.entries.first?.children.first?.title, "User Named App")
        XCTAssertEqual(cached.0.entries.first?.children.first?.path, "/fixture/app")
        XCTAssertEqual(cached.0.entries.first?.bytes, 10)
    }

    func testUnknownOverviewCategoryDoesNotPretendToBeTranslated() {
        var overview = fixture()
        overview.entries = [.init(id: "unknown", title: "Custom English Heading", bytes: 10, children: [])]
        L10n.override = .simplifiedChinese
        XCTAssertNil(overview.localizedForCurrentLanguage())
    }

    func testCacheRejectsInvalidCapacityAndDuplicateOrNegativeEntries() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var capacity = fixture(); capacity.free = 200
        var negative = fixture(); negative.entries = [.init(id: "a", title: "A", bytes: -1, children: [])]
        var duplicate = fixture(); duplicate.entries = [.init(id: "a", title: "A", bytes: 1, children: []), .init(id: "a", title: "A", bytes: 2, children: [])]
        for overview in [capacity, negative, duplicate] {
            try JSONEncoder().encode(overview).write(to: url)
            XCTAssertNil(SpaceOverview.cached(from: url, now: Date(timeIntervalSince1970: 200)))
        }
    }
}
