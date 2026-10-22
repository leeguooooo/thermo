import XCTest
@testable import SearchCore

final class SearchCoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-search-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return URL(fileURLWithPath: SearchPaths.canonical(url.path))
    }
    func testExplicitIntentWinsOverUsageAndAliasesPersist() throws {
        let dir = try directory(), store = try SearchStore(directory: dir)
        let calculator = SearchItem(path: "/Applications/Calculator.app", name: "Calculator", kind: .application)
        let calendar = SearchItem(path: "/Applications/Calendar.app", name: "Calendar", kind: .application)
        try store.replaceApplications([calculator, calendar], complete: true)
        for _ in 0..<10 { try store.recordOpen(calendar.path) }
        XCTAssertEqual(try store.query("Calculator").items.first?.path, calculator.path)
        try store.setAlias("calc", for: calculator.path)
        XCTAssertEqual(try store.query("calc").items.first?.path, calculator.path)
        let reopened = try SearchStore(directory: dir)
        XCTAssertEqual(try reopened.query("calc").items.first?.alias, "calc")
        try reopened.clearHistory()
        XCTAssertEqual(try reopened.query("Calendar").items.first?.visits, 0)
        for _ in 0..<10 { try reopened.recordOpen(calculator.path) }
        XCTAssertEqual(try reopened.query("Cal").items.first?.path, calculator.path)
    }
    func testFileIndexFindsSubsequencesTyposAndCJKWithoutSpotlight() throws {
        let dir = try directory(), store = try SearchStore(directory: dir.appendingPathComponent("db"))
        var prefs = SearchPreferences(); prefs.roots = [dir.path]; try store.savePreferences(prefs)
        let items = [SearchItem(path: dir.path + "/Quarterly Report.pdf", name: "Quarterly Report.pdf", kind: .file),
                     SearchItem(path: dir.path + "/budget.txt", name: "budget.txt", kind: .file),
                     SearchItem(path: dir.path + "/项目说明书.pdf", name: "项目说明书.pdf", kind: .file)]
        try store.upsert(items, root: dir.path, generation: "one")
        try store.markRoot(dir.path, count: 3, issue: nil, available: true, completed: true)
        XCTAssertEqual(try store.query("qrp").items.first?.name, "Quarterly Report.pdf")
        XCTAssertEqual(try store.query("budegt").items.first?.name, "budget.txt")
        XCTAssertEqual(try store.query("说明").items.first?.name, "项目说明书.pdf")
        XCTAssertEqual(try store.query("shuoming").items.first?.name, "项目说明书.pdf")
        XCTAssertTrue(try store.query("no-such-file").items.isEmpty)
        XCTAssertTrue(try store.query("\" OR *").items.isEmpty)
        XCTAssertThrowsError(try store.query("a\0b"))
    }
    func testIncompleteScanCannotRemoveUnseenFilesAndScopeDeletionIsBounded() throws {
        let dir = try directory(), store = try SearchStore(directory: dir.appendingPathComponent("db"))
        var prefs = SearchPreferences(); prefs.roots = [dir.path]; try store.savePreferences(prefs)
        let a = SearchItem(path: dir.path + "/a/report.txt", name: "report.txt", kind: .file)
        let b = SearchItem(path: dir.path + "/ab/report.txt", name: "report.txt", kind: .file)
        try store.upsert([a, b], root: dir.path, generation: "old")
        try store.finishScan(root: dir.path, generation: "new", complete: false)
        XCTAssertEqual(try store.query("report").items.count, 2)
        try store.finishScan(root: dir.path, generation: "new", complete: true, scope: dir.path + "/a")
        XCTAssertEqual(try store.query("report").items.map(\.path), [b.path])
        try store.markRoot(dir.path, count: 1, issue: "Offline", available: false, completed: false)
        let response = try store.query("report")
        XCTAssertTrue(response.items.isEmpty); XCTAssertFalse(response.complete); XCTAssertTrue(response.issues.contains("Offline"))
    }
    func testScannerRespectsInheritedIgnoreRulesAndDoesNotFollowSymlinks() throws {
        let root = try directory(), outside = try directory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        for file in ["keep.txt", "drop.tmp", "nested/visible.txt", "nested/secret.log"] { try Data().write(to: root.appendingPathComponent(file)) }
        try Data("*.log\n*.tmp\n!drop.tmp\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try Data().write(to: outside.appendingPathComponent("outside.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        var items: [SearchItem] = []
        let response = try SearchFileScanner.scan(root: root, preferences: SearchPreferences(), cancellation: SearchCancellation()) { items += $0 }
        XCTAssertTrue(response.complete)
        XCTAssertTrue(items.contains { $0.name == "drop.tmp" })
        XCTAssertFalse(items.contains { $0.name == "secret.log" || $0.name == "outside.txt" })
        items = []
        _ = try SearchFileScanner.scan(root: root, scope: root.appendingPathComponent("nested"), preferences: SearchPreferences(), cancellation: SearchCancellation()) { items += $0 }
        XCTAssertEqual(items.map(\.name), ["visible.txt"])
    }
    func testApplicationCatalogIncludesLocalizedMetadataWithoutSizing() throws {
        let root = try directory(), bundle = root.appendingPathComponent("工具.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.thermo.search", "CFBundleName": "Tools", "CFBundleDisplayName": "工具箱", "CFBundleExecutable": "toolbox"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let report = ApplicationCatalog.scan(roots: [root])
        XCTAssertTrue(report.complete); XCTAssertEqual(report.items.first?.name, "工具箱")
        XCTAssertEqual(SearchRanking.sorted(report.items, query: "toolbox").first?.path, bundle.path)
        XCTAssertEqual(SearchRanking.sorted(report.items, query: "工具").count, 1)
    }
    func testCancelledQueryAndOverlappingRootsAreRejected() throws {
        let dir = try directory(), store = try SearchStore(directory: dir.appendingPathComponent("db"))
        var prefs = SearchPreferences(); prefs.roots = [dir.path, dir.appendingPathComponent("nested").path]
        XCTAssertThrowsError(try store.savePreferences(prefs))
        let token = SearchCancellation(); token.cancel()
        XCTAssertThrowsError(try store.query("abc", cancellation: token))
        prefs.roots = ["/", dir.path]
        XCTAssertThrowsError(try store.savePreferences(prefs))
        XCTAssertTrue(SearchPaths.isWithin("/Users/name", root: "/"))
        XCTAssertFalse(SearchPaths.isWithin("/ab/file", root: "/a"))
    }
    func testIgnoreCharacterClassesTrailingSpacesAndRootBoundary() throws {
        let rule = try XCTUnwrap(SearchIgnoreRule("[Bb]uild/   ", base: "/project"))
        XCTAssertTrue(rule.matches("/project/nested/Build", directory: true))
        XCTAssertFalse(rule.matches("/project/nested/Build", directory: false))
        let literalSpace = try XCTUnwrap(SearchIgnoreRule("notes\\ ", base: "/project"))
        XCTAssertTrue(literalSpace.matches("/project/notes ", directory: false))
        XCTAssertFalse(literalSpace.matches("/project/notes", directory: false))
        let root = try XCTUnwrap(SearchIgnoreRule("*.tmp", base: "/"))
        XCTAssertTrue(root.matches("/Users/name/file.tmp", directory: false))
    }
    func testCustomApplicationPackageIsSearchableButHiddenWhenItsVolumeIsUnavailable() throws {
        let root = try directory(), bundle = root.appendingPathComponent("Portable.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.thermo.portable", "CFBundleName": "Portable Tools", "CFBundleExecutable": "portable"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let store = try SearchStore(directory: root.appendingPathComponent("index"))
        var prefs = SearchPreferences(); prefs.roots = [root.path]; try store.savePreferences(prefs)
        var items: [SearchItem] = []
        let report = try SearchFileScanner.scan(root: root, preferences: prefs, cancellation: SearchCancellation(), excludingPaths: [store.directory.path]) { items += $0 }
        XCTAssertTrue(report.complete)
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items.first?.kind, .application)
        try store.upsert(items, root: root.path, generation: "one")
        try store.markRoot(root.path, count: report.count, issue: nil, available: true, completed: true)
        XCTAssertEqual(try store.query("Portable Tools").items.first?.path, bundle.path)
        try store.markRoot(root.path, count: 1, issue: "Offline", available: false, completed: false)
        XCTAssertTrue(try store.query("Portable Tools").items.isEmpty)
    }
}
