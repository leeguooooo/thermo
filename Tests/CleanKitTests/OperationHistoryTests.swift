import XCTest
import AgentCore
import ThermoL10n
@testable import CleanKit

final class OperationHistoryTests: XCTestCase {
    var home: String!
    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "history-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: home); L10n.override = nil }

    func log(_ r: CleanResult, title: String = "Xcode") {
        Cleaner.log(r, item: CleanItem(id: r.id, category: .system, title: title, safety: .review), to: Cleaner.logURL(home: home))
    }

    func testCleanupTrashBatchIsRecordedWithItsUndo() {
        var r = CleanResult(id: "xcode-derived-data", trashed: true)
        r.removed = ["/a", "/b"]; r.bytes = 300; r.trashBatchID = "B-1"; r.failed = ["/c": "in use"]
        log(r)
        let record = OperationJournal.read(home: home).first
        XCTAssertEqual(record?.feature, "clean")
        XCTAssertEqual(record?.action, "trash")
        XCTAssertEqual(record?.outcome, "partial")
        XCTAssertEqual(record?.bytes, 300)
        XCTAssertEqual(record?.items.map(\.status), ["done", "done", "failed"])
        XCTAssertEqual(record?.undo, .init(kind: "trashBatch", ref: "B-1"))
        XCTAssertTrue(record?.restorableHere == true)
        // The legacy text log is still written.
        XCTAssertTrue(((try? String(contentsOf: Cleaner.logURL(home: home), encoding: .utf8)) ?? "").contains("trashBatch=B-1"))
    }

    func testFeaturesAreTellApartByResultID() {
        var app = CleanResult(id: "app:com.example", trashed: true); app.removed = ["/Applications/Example.app"]; app.bytes = 10
        var manual = CleanResult(id: "manual", trashed: true); manual.removed = ["/x"]
        var empty = CleanResult(id: "trash-batch/B", trashed: false); empty.removed = ["/y"]
        var deleted = CleanResult(id: "npm-cache", trashed: false); deleted.removed = ["/z"]; deleted.bytes = 5; deleted.bytesIncomplete = true
        for r in [app, manual, empty, deleted] { log(r) }
        let byAction = Dictionary(OperationJournal.read(home: home).map { ($0.feature + "/" + $0.action, $0) }, uniquingKeysWith: { a, _ in a })
        // Uninstalls and hand-picked moves record themselves; the cleanup log must not record them twice.
        XCTAssertEqual(Set(byAction.keys), ["clean/emptyTrash", "clean/delete"])
        XCTAssertNil(byAction["clean/emptyTrash"]?.undo)
        XCTAssertNil(byAction["clean/delete"]?.items.first?.bytes, "a single path with an incomplete size is not given an exact size")
        L10n.override = .english
        XCTAssertEqual(byAction["clean/delete"]?.undoText, "Deleted for good; nothing to restore.")
        L10n.override = .simplifiedChinese
        XCTAssertEqual(byAction["clean/delete"]?.title, "清理时删除了文件")
    }

    func testNothingRemovedNothingFailedRecordsNothing() {
        log(CleanResult(id: "empty", trashed: true))
        XCTAssertTrue(OperationJournal.read(home: home).isEmpty)
    }
}
