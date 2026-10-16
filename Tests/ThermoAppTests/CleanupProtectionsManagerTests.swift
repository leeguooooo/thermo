import XCTest
import CleanKit
import Darwin
@testable import ThermoApp

final class CleanupProtectionsManagerTests: XCTestCase {
    var home = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("protections-manager-" + UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func testReadFailureDoesNotBecomeAnEmptyList() throws {
        try Whitelist.add([home + "/one"], home: home)
        let model = CleanupProtectionsModel(home: home); model.reload()
        XCTAssertEqual(model.entries.count, 1)
        let file = Whitelist.url(home: home)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        model.reload()
        XCTAssertNil(model.review); XCTAssertNotNil(model.issue); XCTAssertFalse(model.canChange)
    }
    func testStaleListRequiresRefreshBeforeAllowingRule() throws {
        try Whitelist.add([home + "/one"], home: home)
        let model = CleanupProtectionsModel(home: home); model.reload()
        try Whitelist.add([home + "/two"], home: home)
        XCTAssertFalse(model.allow(home + "/one")); XCTAssertFalse(model.canChange)
        XCTAssertEqual(try Whitelist.loadForRemoval(home: home).entries.count, 2)
        model.reload()
        XCTAssertTrue(model.allow(home + "/one"))
        XCTAssertEqual(model.entries, [home + "/two"])
        XCTAssertNotNil(model.notice)
    }
    func testRuleManagementInvalidatesOldSelectionsAndLocalUndo() throws {
        let item = CleanItem(id: "fixture", category: .system, title: "Fixture", safety: .safe, bytes: 1, paths: [home + "/cache"])
        let disk = DiskModel(report: .init(items: [item], denied: [], started: Date(), duration: 0))
        disk.alwaysKeep(item, home: home)
        XCTAssertNotNil(disk.protectionUndo)
        let model = CleanupProtectionsModel(home: home); model.reload()
        XCTAssertTrue(model.allow(home + "/cache"))
        disk.protectionRulesChanged()
        XCTAssertNil(disk.report); XCTAssertNil(disk.protectionUndo); XCTAssertTrue(disk.selected.isEmpty)
        XCTAssertNotNil(disk.protectionNotice)
    }
    func testEarlierSuccessNoticeDoesNotSurviveARefusedDifferentRemoval() throws {
        try Whitelist.add([home + "/one", home + "/two"], home: home)
        let model = CleanupProtectionsModel(home: home); model.reload()
        XCTAssertTrue(model.allow(home + "/one")); XCTAssertNotNil(model.notice)
        try Whitelist.add([home + "/external"], home: home)
        XCTAssertFalse(model.allow(home + "/two"))
        XCTAssertNil(model.notice); XCTAssertNotNil(model.issue)
        model.reload()
        XCTAssertNil(model.notice); XCTAssertNil(model.issue)
    }

}
