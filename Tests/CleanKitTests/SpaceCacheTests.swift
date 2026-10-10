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
