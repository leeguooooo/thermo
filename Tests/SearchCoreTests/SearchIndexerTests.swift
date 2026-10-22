import XCTest
@testable import SearchCore

final class SearchIndexerTests: XCTestCase {
    func testExternalRenameAndDeletionReconcileWithoutSearchTimeWalks() async throws {
        let base = URL(fileURLWithPath: SearchPaths.canonical(FileManager.default.temporaryDirectory.appendingPathComponent("thermo-search-watch-test-" + UUID().uuidString).path))
        let files = base.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let store = try SearchStore(directory: base.appendingPathComponent("index"))
        var preferences = SearchPreferences(); preferences.roots = [files.path]; try store.savePreferences(preferences)
        let indexer = SearchIndexer(store: store)
        defer { indexer.stop(); try? FileManager.default.removeItem(at: base) }
        indexer.start()
        try await eventually { try store.rootsReport().first?.indexedAt ?? 0 > 0 }
        let before = files.appendingPathComponent("before-g7e.txt"), after = files.appendingPathComponent("after-b4d.txt")
        try process("/usr/bin/touch", [before.path])
        try await eventually { try store.query("before-g7e").items.contains { $0.path == before.path } }
        try process("/bin/mv", [before.path, after.path])
        try await eventually {
            let old = try store.query("before-g7e").items
            let new = try store.query("after-b4d").items
            return old.isEmpty && new.contains { $0.path == after.path }
        }
        try process("/bin/rm", [after.path])
        try await eventually { try store.query("after-b4d").items.isEmpty }
    }
    func testIndexDoesNotIndexItsOwnDatabaseAndExclusionsAreReconciled() throws {
        let base = URL(fileURLWithPath: SearchPaths.canonical(FileManager.default.temporaryDirectory.appendingPathComponent("thermo-search-self-test-" + UUID().uuidString).path))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let index = base.appendingPathComponent("private-index")
        let store = try SearchStore(directory: index)
        try Data().write(to: base.appendingPathComponent("keep.txt"))
        var items: [SearchItem] = []
        let report = try SearchFileScanner.scan(root: base, preferences: SearchPreferences(), cancellation: SearchCancellation(), excludingPaths: [index.path]) { items += $0 }
        XCTAssertTrue(report.complete)
        XCTAssertEqual(items.map(\.name), ["keep.txt"])
        var prefs = SearchPreferences(); prefs.roots = [base.path]; try store.savePreferences(prefs)
        try store.upsert(items, root: base.path, generation: "old")
        prefs.excludedPatterns.append("keep.txt"); items = []
        _ = try SearchFileScanner.scan(root: base, preferences: prefs, cancellation: SearchCancellation(), excludingPaths: [index.path]) { items += $0 }
        try store.upsert(items, root: base.path, generation: "new")
        try store.finishScan(root: base.path, generation: "new", complete: true)
        XCTAssertTrue(try store.query("keep").items.isEmpty)
    }
    func testRestartReconcilesChangesWhileWatcherWasStopped() throws {
        let base = URL(fileURLWithPath: SearchPaths.canonical(FileManager.default.temporaryDirectory.appendingPathComponent("thermo-search-restart-test-" + UUID().uuidString).path))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let database = base.appendingPathComponent("db"), files = base.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let old = files.appendingPathComponent("old.txt"), new = files.appendingPathComponent("new.txt")
        try Data().write(to: old)
        let store = try SearchStore(directory: database)
        var prefs = SearchPreferences(); prefs.roots = [files.path]; try store.savePreferences(prefs)
        func scan(_ generation: String, _ store: SearchStore) throws {
            let report = try SearchFileScanner.scan(root: files, preferences: prefs, cancellation: SearchCancellation()) { try store.upsert($0, root: files.path, generation: generation) }
            try store.finishScan(root: files.path, generation: generation, complete: report.complete)
        }
        try scan("before", store)
        try FileManager.default.moveItem(at: old, to: new)
        let reopened = try SearchStore(directory: database)
        try scan("after", reopened)
        XCTAssertTrue(try reopened.query("old.txt").items.isEmpty)
        XCTAssertEqual(try reopened.query("new.txt").items.first?.path, new.path)
    }
    private func process(_ executable: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }
    private func eventually(_ predicate: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if try predicate() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Filesystem changes did not reconcile within 15 seconds")
    }
}
