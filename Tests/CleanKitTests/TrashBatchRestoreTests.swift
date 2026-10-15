import AgentCore
import Darwin
import XCTest
@testable import CleanKit

final class TrashBatchRestoreTests: XCTestCase {
    var home = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-restore-" + UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: home) }
    func file(_ path: String, bytes: Int = 4096) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 37, count: bytes).write(to: URL(fileURLWithPath: path))
    }
    /// Stands in for Finder's Trash: moves into `home/.Trash` and returns the new location.
    func move(_ path: String) throws -> URL {
        let trash = home + "/.Trash"
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        let destination = URL(fileURLWithPath: trash).appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: URL(fileURLWithPath: path), to: destination)
        return destination
    }
    func trashed(_ paths: [String]) throws -> TrashBatch {
        let result = ManualRemoval.trash(paths, sizes: [:], home: home, move: move)
        XCTAssertTrue(result.failed.isEmpty, "\(result.failed)")
        return try TrashBatches.load(XCTUnwrap(result.trashBatchID), home: home)
    }

    /// Journal times have whole-second precision, so pick the restore record by feature.
    func history() -> OperationRecord? { OperationJournal.read(home: home).first { $0.feature == "history" } }

    func testManualTrashRecordsABatchAndJournal() throws {
        let path = home + "/Downloads/fixture.bin"
        try file(path)
        let result = ManualRemoval.trash([path], sizes: [path: 4096], home: home, move: move)
        let id = try XCTUnwrap(result.trashBatchID)
        let batch = try TrashBatches.load(id, home: home)
        XCTAssertEqual(batch.entries.map(\.original), [path])
        XCTAssertNil(TrashBatches.refusal(batch.entries[0], home: home))
        let record = try XCTUnwrap(OperationJournal.read(home: home).first)
        XCTAssertEqual(record.feature, "space"); XCTAssertEqual(record.action, "trash")
        XCTAssertEqual(record.undo, .init(kind: "trashBatch", ref: id))
        XCTAssertEqual(record.items, [.init(target: path, bytes: 4096, status: "done")])
    }

    func testAppTrashRecordsABatchAndEmptyTrashRemovesOnlyIt() throws {
        let app = home + "/Applications/Fixture.app"
        try file(app + "/Contents/Info.plist")
        var result = CleanResult(id: "app:fixture", trashed: true)
        AppUninstaller.trash([app], bundleIDs: ["com.example.fixture"], sizes: [app: 4096], home: home,
                             processes: { ProcessTable(entries: []) }, into: &result, move: move)
        AppUninstaller.finish(result, title: "Fixture", home: home, action: "uninstall", subject: "com.example.fixture", sizes: [:])
        XCTAssertTrue(result.failed.isEmpty, "\(result.failed)")
        let id = try XCTUnwrap(result.trashBatchID)
        try file(home + "/.Trash/unrelated")
        XCTAssertEqual(try TrashBatches.empty(id, home: home).outcome, "success")
        XCTAssertTrue(FS.exists(home + "/.Trash/unrelated"))
        let record = try XCTUnwrap(OperationJournal.read(home: home).first)
        XCTAssertEqual(record.feature, "apps"); XCTAssertEqual(record.action, "uninstall")
        XCTAssertEqual(record.undo?.ref, id)
        XCTAssertNil(record.items.first?.bytes, "unknown size stays unknown")
    }

    func testRestorePutsItemsBackAndJournalsIt() throws {
        let a = home + "/Downloads/a.bin", b = home + "/Documents/folder/b.bin"
        try file(a); try file(b)
        let batch = try trashed([a, home + "/Documents/folder"])
        let result = try TrashBatches.restore(id: batch.id, home: home)
        XCTAssertEqual(result.items.map(\.status), ["restored", "restored"])
        XCTAssertTrue(FS.exists(a)); XCTAssertTrue(FS.exists(b))
        XCTAssertTrue(batch.entries.allSatisfy { !FS.exists($0.destination) })
        let record = try XCTUnwrap(history())
        XCTAssertEqual(record.feature, "history"); XCTAssertEqual(record.action, "restore"); XCTAssertEqual(record.subject, batch.id)
        XCTAssertEqual(record.items.map(\.status), ["done", "done"])
    }

    func testRestoreNeverOverwritesNewDataAtTheOriginalPath() throws {
        let path = home + "/Downloads/a.bin"
        try file(path)
        let batch = try trashed([path])
        try file(path, bytes: 10)
        let result = try TrashBatches.restore(id: batch.id, home: home)
        XCTAssertEqual(result.items.first?.status, "conflict")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)).count, 10)
        XCTAssertTrue(FS.exists(batch.entries[0].destination))
        XCTAssertEqual(history()?.items.first?.status, "failed")
    }

    func testRestoreRefusesAReplacedTrashItem() throws {
        let path = home + "/Downloads/a.bin"
        try file(path)
        let batch = try trashed([path])
        let destination = batch.entries[0].destination
        try FileManager.default.removeItem(atPath: destination)
        try file(destination, bytes: 10)
        let result = try TrashBatches.restore(id: batch.id, home: home)
        XCTAssertEqual(result.items.first?.status, "changed")
        XCTAssertFalse(FS.exists(path))
        XCTAssertTrue(FS.exists(destination))
    }

    func testRestoreReportsMissingAndGoneParent() throws {
        let a = home + "/Downloads/a.bin", b = home + "/Documents/sub/b.bin"
        try file(a); try file(b)
        let batch = try trashed([a, b])
        let destA = try XCTUnwrap(batch.entries.first { $0.original == a }).destination
        try FileManager.default.removeItem(atPath: destA)
        try FileManager.default.removeItem(atPath: home + "/Documents/sub")
        let result = try TrashBatches.restore(id: batch.id, home: home)
        XCTAssertEqual(result.items.first { $0.original == a }?.status, "missing")
        XCTAssertEqual(result.items.first { $0.original == b }?.status, "skipped")
        XCTAssertFalse(FS.exists(home + "/Documents/sub"))
    }

    func testRestoreSkipsWorktreeRegistrationEntries() throws {
        let path = home + "/repo/.claude/worktrees/x"
        try file(path + "/data")
        let destination = try move(path)
        var entry = TrashBatch.Entry(original: path, destination: destination.path, identity: try XCTUnwrap(FileIdentity.of(destination.path)), bytes: 4096)
        entry.registrationBackup = destination.path + "/.thermo-registration"
        let id = UUID().uuidString
        try TrashBatches.append(entry, id: id, home: home)
        let result = try TrashBatches.restore(id: id, home: home)
        XCTAssertEqual(result.items.first?.status, "skipped")
        XCTAssertFalse(FS.exists(path))
        XCTAssertTrue(FS.exists(destination.path))
        XCTAssertEqual(history()?.items.first?.status, "skipped")
    }

    func testDryRunChangesNothing() throws {
        let path = home + "/Downloads/a.bin"
        try file(path)
        let batch = try trashed([path])
        let before = OperationJournal.read(home: home).count
        let result = try TrashBatches.restore(id: batch.id, home: home, dryRun: true)
        XCTAssertTrue(result.dryRun)
        XCTAssertEqual(result.items.first?.status, "restored")
        XCTAssertFalse(FS.exists(path))
        XCTAssertTrue(FS.exists(batch.entries[0].destination))
        XCTAssertEqual(OperationJournal.read(home: home).count, before)
    }

    func testEmptyTrashAfterRestoreKeepsRestoredItems() throws {
        let a = home + "/Downloads/a.bin", b = home + "/Downloads/b.bin"
        try file(a); try file(b)
        let batch = try trashed([a, b])
        let destA = try XCTUnwrap(batch.entries.first { $0.original == a }).destination
        // Only `a` comes back; `b`'s original path is taken so it stays in the Trash.
        try file(b, bytes: 10)
        let restored = try TrashBatches.restore(id: batch.id, home: home)
        XCTAssertEqual(restored.items.first { $0.original == a }?.status, "restored")
        // A new item later takes the restored entry's old Trash name: it is not this batch's.
        try file(destA, bytes: 10)
        let emptied = try TrashBatches.empty(batch.id, home: home)
        XCTAssertNotNil(emptied.failed[destA])
        XCTAssertTrue(FS.exists(a)); XCTAssertTrue(FS.exists(destA)); XCTAssertTrue(FS.exists(b))
        XCTAssertEqual(emptied.removed.count, 1)
    }

    func testRestoreRejectsAnInvalidBatchID() {
        XCTAssertThrowsError(try TrashBatches.restore(id: "../../etc", home: home))
    }
}
