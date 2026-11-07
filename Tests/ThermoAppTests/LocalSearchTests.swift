import XCTest
import Carbon
import SearchCore
@testable import ThermoApp

@MainActor final class LocalSearchTests: XCTestCase {
    func testSlowOldQueryCannotReplaceNewResultsOrBeOpened() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-search-ui-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let model = LocalSearchModel(directory: directory) { term, _ in
            if term == "old" { entered.signal(); _ = release.wait(timeout: .now() + 3) }
            return SearchResponse(query: term, items: [SearchItem(path: "/" + term, name: term, kind: .file)])
        }
        model.query = "old"
        let didEnter = await Task.detached { Self.admitted(entered) }.value
        XCTAssertTrue(didEnter)
        model.query = "new"
        XCTAssertNil(model.selected)
        for _ in 0..<100 where model.response.query != "new" { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.response.query, "new")
        XCTAssertEqual(model.selected?.name, "new")
        release.signal()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(model.response.query, "new")
        model.stop()
    }
    func testSelectionStaysOnIdentityAfterResultsReorder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-search-ui-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = LocalSearchModel(directory: directory) { term, _ in
            let a = SearchItem(path: "/a", name: "A", kind: .file), b = SearchItem(path: "/b", name: "B", kind: .file)
            return SearchResponse(query: term, items: term == "a" ? [a, b] : [b, a])
        }
        model.query = "a"
        for _ in 0..<100 where model.response.query != "a" { try await Task.sleep(nanoseconds: 10_000_000) }
        model.selection = "/a"; model.query = "b"
        for _ in 0..<100 where model.response.query != "b" { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.selected?.path, "/a")
        model.stop()
    }
    func testPastedPathSelectsUnindexedFileAndClearsStaleActions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-path-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("说明 report.pdf")
        try Data().write(to: file)
        let model = LocalSearchModel(directory: directory.appendingPathComponent("db"))
        model.query = file.path
        for _ in 0..<100 where model.response.query != file.path { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.selected?.name, file.lastPathComponent)
        XCTAssertEqual(model.directPath, SearchDirectPath.path(from: file.path))
        XCTAssertTrue(model.canOpenInPreview)
        model.query = directory.appendingPathComponent("missing.pdf").path
        XCTAssertNil(model.selected)
        XCTAssertFalse(model.canOpenInPreview)
        for _ in 0..<100 where model.response.query != model.query { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(model.directPath)
        XCTAssertTrue(model.response.items.isEmpty)
        for (name, kind, expected) in [("image.png", SearchItemKind.file, true), ("movie.mp4", .file, false), ("notes.md", .file, false), ("folder.pdf", .folder, false), ("Preview.app", .application, false)] {
            XCTAssertEqual(model.canOpenInPreview(SearchItem(path: "/tmp/" + name, name: name, kind: kind)), expected)
        }
        model.stop()
    }
    func testSearchShortcutConflictPreservesPreviousLeaseAndSuppressesRepeat() throws {
        let backend = Backend(); var calls = 0
        let model = LocalSearchShortcut(backend: backend) { calls += 1 }
        let first = CleanScreenKeyBinding(keyCode: 49, modifiers: UInt32(optionKey), keyLabel: "Space")
        XCTAssertTrue(first.validForSearch); XCTAssertFalse(first.valid)
        model.apply(first, persist: false)
        backend.callback?(true); backend.callback?(true); backend.callback?(false); backend.callback?(true)
        XCTAssertEqual(calls, 2)
        backend.fail = true
        model.apply(.init(keyCode: 3, modifiers: UInt32(cmdKey), keyLabel: "F"), persist: false)
        XCTAssertEqual(model.binding, first); XCTAssertNotNil(model.issue); XCTAssertFalse(backend.lease.released)
        model.shutdown(); XCTAssertTrue(backend.lease.released)
    }
    func testSpotlightTakeoverRestoresWhenLeavingCommandSpace() throws {
        let backend = Backend(); var spotlightOn = true, backup = false
        var holder: SpotlightShortcut.Holder?
        let spotlight = SpotlightShortcut(commandSpaceTaken: { spotlightOn },
                                          release: { backup = true; spotlightOn = false },
                                          restore: { if backup { spotlightOn = true; backup = false } },
                                          released: { backup }, otherHolder: { holder })
        let model = LocalSearchShortcut(backend: backend, spotlight: spotlight, action: {}, record: { _ in })
        model.apply(LocalSearchShortcut.optionSpace, persist: false)
        model.takeOverSpotlight()
        XCTAssertEqual(model.binding, LocalSearchShortcut.commandSpace); XCTAssertFalse(spotlightOn); XCTAssertTrue(model.spotlightReleased)
        model.apply(.init(keyCode: 3, modifiers: UInt32(cmdKey), keyLabel: "F"), persist: false)
        XCTAssertTrue(spotlightOn); XCTAssertFalse(model.spotlightReleased)
        model.takeOverSpotlight(); model.giveBackToSpotlight()
        XCTAssertTrue(spotlightOn); XCTAssertEqual(model.binding, LocalSearchShortcut.optionSpace)
        backend.fail = true; model.takeOverSpotlight()
        XCTAssertTrue(spotlightOn); XCTAssertFalse(backup); XCTAssertEqual(model.binding, LocalSearchShortcut.optionSpace); XCTAssertNotNil(model.issue)
        // A known holder is reported before Spotlight is touched.
        backend.fail = false; holder = .init(name: "Raycast", app: URL(fileURLWithPath: "/Applications/Raycast.app"))
        model.takeOverSpotlight()
        XCTAssertTrue(spotlightOn); XCTAssertEqual(model.commandSpaceHolder, holder); XCTAssertEqual(model.binding, LocalSearchShortcut.optionSpace)
    }
    private final class Lease: CleanScreenHotkeyLease {
        var released = false
        func release() throws { released = true }
    }
    nonisolated private static func admitted(_ semaphore: DispatchSemaphore) -> Bool { semaphore.wait(timeout: .now() + 2) == .success }
    private final class Backend: CleanScreenHotkeyBackend {
        let lease = Lease()
        var fail = false
        var callback: ((Bool) -> Void)?
        func register(_ binding: CleanScreenKeyBinding, event: @escaping (Bool) -> Void) throws -> CleanScreenHotkeyLease {
            if fail { throw NSError(domain: "shortcut-test", code: 1) }
            callback = event; return lease
        }
    }
    func testDefaultFoldersAreAddedOnceAndOnlyForUsersWithoutFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-defaults-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        for name in ["Desktop", "Documents"] { try FileManager.default.createDirectory(at: home.appendingPathComponent(name), withIntermediateDirectories: true) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "search-defaults-" + UUID().uuidString))
        let model = LocalSearchModel(directory: root.appendingPathComponent("db"))
        model.applyDefaultFoldersOnce(defaults: defaults, home: home.path)
        // Downloads does not exist here, so only the two real folders are added.
        XCTAssertEqual(model.preferences.roots.map { ($0 as NSString).lastPathComponent }, ["Desktop", "Documents"])
        // Removed later: never re-added.
        var none = model.preferences; none.roots = []; model.configure(none)
        model.applyDefaultFoldersOnce(defaults: defaults, home: home.path)
        XCTAssertTrue(model.preferences.roots.isEmpty)
        // Someone who already chose folders keeps exactly those.
        let chosen = LocalSearchModel(directory: root.appendingPathComponent("db2"))
        var mine = chosen.preferences; mine.roots = [home.appendingPathComponent("Documents").path]; chosen.configure(mine)
        let fresh = try XCTUnwrap(UserDefaults(suiteName: "search-defaults-" + UUID().uuidString))
        chosen.applyDefaultFoldersOnce(defaults: fresh, home: home.path)
        XCTAssertEqual(chosen.preferences.roots, mine.roots)
    }

}
