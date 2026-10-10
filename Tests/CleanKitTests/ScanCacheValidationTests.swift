import XCTest
import CleanKit

final class ScanCacheValidationTests: XCTestCase {
    func fixture() -> ScanReport {
        ScanReport(items: [.init(id: "fixture", category: .devCaches, title: "Fixture", safety: .safe, bytes: 10, paths: ["/fixture/cache"])],
                   denied: [], started: Date(timeIntervalSince1970: 100), duration: 1)
    }

    func testInvalidReportsCannotBeLoaded() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = ScanReportCache.url(home: home.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cancelled = fixture(); cancelled.cancelled = true
        var negative = fixture(); negative.items[0].bytes = -1
        var duplicate = fixture(); duplicate.items.append(duplicate.items[0])
        var overflow = fixture(); overflow.items[0].bytes = Int64.max
        var second = overflow.items[0]; second.id = "second"; overflow.items.append(second)
        var parts = fixture(); parts.items[0].parts = [.init(id: "p", title: "P", bytes: 1, lastUsed: nil, paths: []),
                                                    .init(id: "p", title: "P", bytes: 1, lastUsed: nil, paths: [])]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        for report in [cancelled, negative, duplicate, overflow, parts] {
            try encoder.encode(report).write(to: url)
            XCTAssertNil(ScanReportCache.load(home: home.path, maxAge: 1000, now: Date(timeIntervalSince1970: 200)))
        }
    }

    func testInvalidSaveKeepsPreviousValidReport() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        ScanReportCache.save(fixture(), home: home.path)
        var invalid = fixture(); invalid.items[0].bytes = -1
        ScanReportCache.save(invalid, home: home.path)
        let loaded = try XCTUnwrap(ScanReportCache.load(home: home.path, maxAge: 1000, now: Date(timeIntervalSince1970: 200)))
        XCTAssertEqual(loaded.items[0].bytes, 10)
    }
}
