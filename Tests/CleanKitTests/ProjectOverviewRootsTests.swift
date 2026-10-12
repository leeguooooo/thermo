import XCTest
@testable import CleanKit

final class ProjectOverviewRootsTests: XCTestCase {
    func testDefaultRootsUseSuppliedHomeAndDeduplicateAliases() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/Developer", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/tk.com", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/Code", withDestinationPath: home + "/Developer")
        try FileManager.default.createSymbolicLink(atPath: home + "/workspace", withDestinationPath: home)
        try Data("not a folder".utf8).write(to: URL(fileURLWithPath: home + "/file.com"))
        let roots = ScanOptions.defaultProjectRoots(home: home)
        XCTAssertEqual(Set(roots), [home + "/Developer", home + "/tk.com"])
    }
    func testNestedRootAliasIsNotCountedTwice() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/Developer/repo", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/src", withDestinationPath: home + "/Developer/repo")
        XCTAssertEqual(ScanOptions.defaultProjectRoots(home: home), [home + "/Developer"])
        XCTAssertEqual(SpaceOverview.projectRoots(home: home), [home + "/Developer"])
    }

    func testProjectHeadingCanBeRelocalizedFromCLIOverview() {
        L10n.override = .simplifiedChinese
        defer { L10n.override = nil }
        var overview = SpaceOverview(capacity: 1000, free: 100, purgeable: 0,
                                     entries: [.init(id: "projects", title: "Projects and source folders", bytes: 500, children: [])], duration: 1)
        overview.language = "en"
        let translated = overview.localizedForCurrentLanguage()
        XCTAssertEqual(translated?.entries.first?.title, tr("Projects and source folders"))
        XCTAssertEqual(translated?.entries.first?.bytes, 500)
    }
}
