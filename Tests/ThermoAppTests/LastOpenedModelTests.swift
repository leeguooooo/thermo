@testable import CleanKit
@testable import ThermoApp
import XCTest

final class LastOpenedModelTests: XCTestCase {
    var root: URL!
    var cache: URL { root.appendingPathComponent("cache.json") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        for name in ["a", "b"] { try Data(name.utf8).write(to: root.appendingPathComponent("Downloads/" + name)) }
        var tree = SpaceLens.scan(root.path)
        tree.large = ["a", "b"].map { .init(path: root.appendingPathComponent("Downloads/" + $0).path, bytes: 1, modified: .distantPast) }
        SpaceLens.save(tree, to: cache)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @MainActor func testRepeatedRequestsKeepOneReaderAndUnknownResultsAreCached() async throws {
        let calls = Calls(), began = expectation(description: "reader"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = SpaceLensModel(root: root.path, cache: cache, readLastOpened: { _ in
            if calls.next() == 1 { began.fulfill(); _ = release.wait(timeout: .now() + 5) }
            return nil
        })
        XCTAssertEqual(model.tree?.large.count, 2)
        model.loadLastOpened(); await fulfillment(of: [began], timeout: 2)
        for _ in 0..<100 { model.loadLastOpened() }
        XCTAssertEqual(calls.count, 1); XCTAssertTrue(model.loadingLastOpened)
        release.signal(); try await idle(model)
        XCTAssertEqual(calls.count, 2); XCTAssertEqual(model.lastOpened.count, 2)
        model.loadLastOpened(); try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(calls.count, 2)
    }

    @MainActor func testStopRetainsPhysicalSlotAndCoalescesReopen() async throws {
        let calls = Calls(), began = expectation(description: "reader"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = SpaceLensModel(root: root.path, cache: cache, readLastOpened: { _ in
            if calls.next() == 1 { began.fulfill(); _ = release.wait(timeout: .now() + 5) }
            return Date(timeIntervalSince1970: 123)
        })
        model.loadLastOpened(); await fulfillment(of: [began], timeout: 2)
        model.stopLastOpened()
        for _ in 0..<100 { model.loadLastOpened() }
        XCTAssertTrue(model.loadingLastOpened); XCTAssertEqual(calls.count, 1)
        release.signal(); try await idle(model)
        XCTAssertEqual(calls.count, 3); XCTAssertEqual(model.lastOpened.count, 2)
    }

    @MainActor func testLeaveDiscardsLateResultsAndDoesNotStartAnotherRead() async throws {
        let calls = Calls(), began = expectation(description: "reader"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = SpaceLensModel(root: root.path, cache: cache, readLastOpened: { _ in
            _ = calls.next(); began.fulfill(); _ = release.wait(timeout: .now() + 5)
            return Date()
        })
        model.loadLastOpened(); await fulfillment(of: [began], timeout: 2)
        model.stopLastOpened(); release.signal(); try await idle(model)
        XCTAssertEqual(calls.count, 1); XCTAssertTrue(model.lastOpened.isEmpty)
    }

    @MainActor func testRestoreInvalidationCancelsMetadataAndDoesNotReadInBackground() async throws {
        let calls = Calls(), began = expectation(description: "reader"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = SpaceLensModel(root: root.path, cache: cache, readLastOpened: { _ in
            _ = calls.next(); began.fulfill(); _ = release.wait(timeout: .now() + 5)
            return Date()
        })
        model.loadLastOpened(); await fulfillment(of: [began], timeout: 2)
        model.invalidateAfterRestore([root.appendingPathComponent("Downloads/a").path])
        release.signal(); try await idle(model)
        XCTAssertEqual(calls.count, 1); XCTAssertTrue(model.lastOpened.isEmpty); XCTAssertNil(model.tree)
    }

    @MainActor func testRequestBeforeScanFinishesReadsTheNewLargeFileList() async throws {
        let tree = try XCTUnwrap(SpaceLens.cached(root: root.path, from: cache))
        try FileManager.default.removeItem(at: cache)
        let calls = Calls()
        let model = SpaceLensModel(root: root.path, cache: cache, measure: { _, _, _ in tree }, readLastOpened: { _ in _ = calls.next(); return nil })
        model.scan(); model.loadLastOpened()
        for _ in 0..<200 where model.scanning || model.loadingLastOpened { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.scanning); XCTAssertFalse(model.loadingLastOpened)
        XCTAssertEqual(calls.count, 2); XCTAssertEqual(model.lastOpened.count, 2)
    }

    @MainActor private func idle(_ model: SpaceLensModel) async throws {
        for _ in 0..<200 where model.loadingLastOpened { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.loadingLastOpened)
    }
    private final class Calls: @unchecked Sendable {
        let lock = NSLock(); private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
}
