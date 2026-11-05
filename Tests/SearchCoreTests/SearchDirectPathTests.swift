import XCTest
@testable import SearchCore

final class SearchDirectPathTests: XCTestCase {
    func testExplicitPathsWorkWithoutRootsOrIndexAndPreservePreferences() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("项目 report (1).pdf")
        try Data().write(to: file)
        let store = try SearchStore(directory: directory.appendingPathComponent("db"))
        try store.setFavorite(true, for: file.path)
        try store.setAlias("report", for: file.path)
        try store.recordOpen(file.path)
        for query in [file.path, "  \"" + file.path + "\"\n", "'" + file.path + "'", file.absoluteString,
                      file.path.replacingOccurrences(of: " ", with: "\\ ").replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")] {
            let response = try store.query(query)
            XCTAssertEqual(response.query, query)
            XCTAssertEqual(response.items.count, 1, query)
            XCTAssertEqual(response.items.first?.path, file.path)
            XCTAssertEqual(response.items.first?.kind, .file)
            XCTAssertEqual(response.items.first?.favorite, true)
            XCTAssertEqual(response.items.first?.alias, "report")
            XCTAssertEqual(response.items.first?.visits, 1)
            XCTAssertTrue(response.complete)
        }
        XCTAssertTrue(try store.preferences().roots.isEmpty)
        XCTAssertTrue(try store.query("report").items.isEmpty, "Explicit lookup must not index the containing folder")
        XCTAssertEqual(try store.query(directory.path + "/").items.first?.kind, .folder)
        let app = directory.appendingPathComponent("Test.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertEqual(try store.query(app.path).items.first?.kind, .application)
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(try store.query(file.path).items.isEmpty)
    }
    func testLongPathsHiddenFilesAndSymlinksRemainExplicit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appendingPathComponent(String(repeating: "a", count: 140)).appendingPathComponent(String(repeating: "b", count: 140))
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent(".hidden.txt")
        try Data().write(to: file)
        let store = try SearchStore(directory: directory.appendingPathComponent("db"))
        XCTAssertGreaterThan(file.path.count, 256)
        XCTAssertEqual(try store.query(file.path).items.first?.path, file.path)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(try store.query(link.path).items.first?.path, link.path)
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(try store.query(link.path).items.isEmpty)
        let token = SearchCancellation(); token.cancel()
        XCTAssertThrowsError(try store.query(directory.path, cancellation: token))
    }
    func testOnlyLocalAbsolutePathsAreAcceptedWithoutShellExpansion() {
        XCTAssertEqual(SearchDirectPath.path(from: "~/"), FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertEqual(SearchDirectPath.path(from: "file://localhost/tmp/example%20file.txt"), "/tmp/example file.txt")
        XCTAssertEqual(SearchDirectPath.path(from: "/tmp/$(touch danger).txt"), "/tmp/$(touch danger).txt")
        for query in ["report.txt", "docs/report.txt", "https://example.com/a", "file://server/tmp/a", "file:///tmp/a?query", "/tmp/a\0b", "open /tmp/a", "~other/a"] {
            XCTAssertNil(SearchDirectPath.path(from: query), query)
        }
    }
}
