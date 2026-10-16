@testable import CleanKit
@testable import ThermoApp
import XCTest

final class SpaceLensModelTests: XCTestCase {
    @MainActor func testConfirmedManualRemovalPinsSelectionAndBlocksQuitUntilWorkerReturns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Downloads/item").path
        try Data("fixture".utf8).write(to: URL(fileURLWithPath: path))
        let expected = try XCTUnwrap(ManualRemoval.reviewIdentity(path))
        let began = expectation(description: "moving"), release = DispatchSemaphore(value: 0), calls = Calls()
        defer { release.signal() }
        let model = SpaceLensModel(root: root.path, cache: root.appendingPathComponent("cache.json"), remove: { paths, _, _, _, identities in
            calls.next(); XCTAssertEqual(paths, [path]); XCTAssertEqual(identities[path], expected)
            began.fulfill(); _ = release.wait(timeout: .now() + 5)
            return CleanResult(id: "manual", trashed: true)
        })
        model.toggle(path, bytes: 7); model.trash()
        await fulfillment(of: [began], timeout: 2)
        model.trash(); model.scan(); model.clearBasket(); model.toggle(path, bytes: 7)
        XCTAssertTrue(model.working); XCTAssertFalse(model.scanning); XCTAssertEqual(model.basket.count, 1); XCTAssertEqual(calls.value, 1)
        var shown: [MainPage] = []
        XCTAssertEqual(AppExitGuard.reply(show: { shown.append($0) }), .terminateCancel)
        XCTAssertEqual(shown, [.space(.browse)]); XCTAssertTrue(model.exitRequested)
        release.signal()
        for _ in 0..<100 where model.working { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.working)
        XCTAssertEqual(AppExitGuard.reply(show: { _ in }), .terminateNow)
    }

    @MainActor func testDeselectAndReselectCaptureTheCurrentIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Downloads/item").path
        try Data("before".utf8).write(to: URL(fileURLWithPath: path))
        let model = SpaceLensModel(root: root.path, cache: root.appendingPathComponent("cache.json"), remove: { paths, sizes, home, incomplete, identities in
            ManualRemoval.trash(paths, sizes: sizes, home: home, incompletePaths: incomplete, reviewIdentities: identities,
                openFiles: { .init(holders: []) }, move: { _ in XCTFail("Stale selection must not move"); return URL(fileURLWithPath: "/unused") })
        })
        model.toggle(path, bytes: 6)
        try Data("after change".utf8).write(to: URL(fileURLWithPath: path))
        model.trash()
        for _ in 0..<100 where model.working { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path)); XCTAssertNotNil(model.outcome)
        model.toggle(path, bytes: 12); XCTAssertTrue(model.basket.isEmpty)
        model.toggle(path, bytes: 12); XCTAssertEqual(model.basket[path], 12)
    }
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    @MainActor
    func testStoppingRetainsPhysicalWorkerAndPublishesPartialInsteadOfOldCompleteTree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache.json")
        let complete = SpaceLens.scan(root.path)
        SpaceLens.save(complete, to: cache)
        var partial = complete
        partial.complete = false; partial.cancelled = true
        partial.folders[root.path]?.entry.sizeState = .unavailable
        let response = partial
        let began = expectation(description: "scan owns worker")
        let release = DispatchSemaphore(value: 0)
        let calls = Calls()
        let model = SpaceLensModel(root: root.path, cache: cache, measure: { _, _, _ in
            calls.next(); began.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
            return response
        })
        XCTAssertEqual(model.tree?.complete, true)
        model.scan()
        await fulfillment(of: [began], timeout: 5)
        model.stop()
        XCTAssertTrue(model.scanning)
        XCTAssertTrue(model.stopping)
        model.scan()
        model.basket = [root.path + "/unused": 0]
        model.trash()
        XCTAssertFalse(model.working)
        XCTAssertEqual(calls.value, 1)
        release.signal()
        for _ in 0..<100 where model.scanning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.scanning)
        XCTAssertFalse(model.stopping)
        XCTAssertEqual(model.tree?.complete, false)
        XCTAssertEqual(model.folder?.entry.effectiveSizeState, .unavailable)
    }
}
