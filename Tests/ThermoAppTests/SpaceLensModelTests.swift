@testable import CleanKit
@testable import ThermoApp
import XCTest

final class SpaceLensModelTests: XCTestCase {
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
