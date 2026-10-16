import XCTest
import CleanKit
@testable import ThermoApp

final class CleanupProtectionTests: XCTestCase {
    var home = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-protection-" + UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func model() -> (DiskModel, CleanItem) {
        let item = CleanItem(id: "fixture-tool", category: .devCaches, title: "fixture", safety: .review, bytes: 1,
                             commands: [["/usr/bin/true"]], commandScope: [home + "/cache", home + "/logs"])
        let model = DiskModel(report: .init(items: [item], denied: [], started: Date(), duration: 0))
        model.selected = [item.id]; return (model, item)
    }
    func testToolLocationCanBeProtectedAndUndoRequiresFreshScan() throws {
        let (model, item) = model()
        model.alwaysKeep(item, paths: [home + "/logs"], home: home)
        XCTAssertNotNil(model.protectionUndo); XCTAssertTrue(model.selectedItems.isEmpty)
        XCTAssertEqual(try Whitelist.loadForRemoval(home: home).entries, [home + "/logs"])
        XCTAssertFalse(try XCTUnwrap(model.report?.items.first).cleanable)
        model.undoProtection()
        XCTAssertNil(model.error); XCTAssertNil(model.protectionUndo)
        XCTAssertNil(model.report); XCTAssertTrue(model.selected.isEmpty)
        XCTAssertTrue(try Whitelist.loadForRemoval(home: home).entries.isEmpty)
        XCTAssertNotNil(model.protectionNotice)
    }
    func testExistingProtectionCannotBeUndoneByNoOpAdd() throws {
        let (model, item) = model()
        try Whitelist.add(item.commandScope!, home: home)
        model.alwaysKeep(item, home: home)
        XCTAssertNil(model.protectionUndo)
        model.undoProtection()
        XCTAssertEqual(Set(try Whitelist.loadForRemoval(home: home).entries), Set(item.commandScope!))
    }
    func testExternalConfigChangeKeepsProtectionAndCurrentReport() throws {
        let (model, item) = model()
        model.alwaysKeep(item, home: home)
        try Whitelist.add([home + "/other"], home: home)
        model.undoProtection()
        XCTAssertNotNil(model.error); XCTAssertNotNil(model.report)
        XCTAssertTrue(try Whitelist.loadForRemoval(home: home).protects(home + "/logs"))
        XCTAssertTrue(try Whitelist.loadForRemoval(home: home).protects(home + "/other"))
    }
}
