@testable import CleanKit
@testable import ThermoApp
import XCTest
import ThermoL10n

final class SpaceLensModelTests: XCTestCase {
    @MainActor func testRemovalFeedbackRetainsUnmovedSelectionsAndMarksFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Downloads/keep"); try Data("owned".utf8).write(to: file)
        let model = SpaceLensModel(root: root.path, cache: root.appendingPathComponent("cache"))
        model.toggle(file.path, bytes: 5)
        var failed = CleanResult(id: "manual", trashed: true); failed.failed[file.path] = "fixture failure"
        model.afterTrash(failed)
        XCTAssertEqual(model.basket[file.path], 5); XCTAssertTrue(model.outcomeIsWarning)
        XCTAssertTrue(try XCTUnwrap(model.outcome).hasPrefix(tr("Nothing was moved to the Trash.")))
        var kept = CleanResult(id: "manual", trashed: true); kept.whitelisted = [file.path]
        model.afterTrash(kept)
        XCTAssertFalse(model.outcomeIsWarning); XCTAssertTrue(try XCTUnwrap(model.outcome).contains(tr("Kept by the whitelist: %1$@", FS.tilde(file.path))))
        var success = CleanResult(id: "manual", trashed: true); success.removed = [file.path]
        model.afterTrash(success)
        XCTAssertTrue(model.basket.isEmpty); XCTAssertFalse(model.outcomeIsWarning)
    }

    @MainActor func testDuplicateSelectionBindsComparisonAndRetainedCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keeper = root.appendingPathComponent("Downloads/keeper").path, extra = root.appendingPathComponent("Downloads/extra").path
        for path in [keeper, extra] { try Data("same".utf8).write(to: URL(fileURLWithPath: path)) }
        let ids = [keeper: try XCTUnwrap(ManualRemoval.reviewIdentity(keeper)), extra: try XCTUnwrap(ManualRemoval.reviewIdentity(extra))]
        let group = DuplicateGroup(hash: "fixture", size: 999999, paths: [keeper, extra], reclaimable: 0, reviewIdentities: ids, privateBytes: [extra: 0], reclaimableState: .complete)
        let model = SpaceLensModel(root: root.path, cache: root.appendingPathComponent("cache"), remove: { paths, sizes, _, _, reviewed, required in
            XCTAssertEqual(paths, [extra]); XCTAssertEqual(sizes[extra], 0)
            XCTAssertEqual(reviewed[extra], ids[extra]); XCTAssertEqual(required, [keeper: ids[keeper]!])
            return CleanResult(id: "fixture", trashed: true)
        }, searchDuplicates: { _, _, _ in [group] })
        model.findDuplicates()
        for _ in 0..<100 where model.findingDuplicates { try await Task.sleep(nanoseconds: 10_000_000) }
        model.toggleDuplicate(keeper, group: group); XCTAssertTrue(model.basket.isEmpty)
        model.toggleDuplicate(extra, group: group); XCTAssertEqual(model.basketBytes, 0); XCTAssertEqual(model.sizeState(extra), .complete)
        model.trash()
        for _ in 0..<100 where model.working { try await Task.sleep(nanoseconds: 10_000_000) }
        model.clearBasket()
        try Data("changed".utf8).write(to: URL(fileURLWithPath: extra))
        model.toggleDuplicate(extra, group: group); XCTAssertTrue(model.basket.isEmpty)
    }

    @MainActor func testUnknownDuplicateAllocationIsNotReportedAsLogicalBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keeper = root.appendingPathComponent("Downloads/keeper").path, extra = root.appendingPathComponent("Downloads/extra").path
        for path in [keeper, extra] { try Data("same".utf8).write(to: URL(fileURLWithPath: path)) }
        let ids = [keeper: try XCTUnwrap(ManualRemoval.reviewIdentity(keeper)), extra: try XCTUnwrap(ManualRemoval.reviewIdentity(extra))]
        let group = DuplicateGroup(hash: "fixture", size: 999999, paths: [keeper, extra], reclaimable: 0, reviewIdentities: ids)
        let model = SpaceLensModel(root: root.path, cache: root.appendingPathComponent("cache"), remove: { paths, sizes, _, incomplete, _, _ in
            XCTAssertEqual(paths, [extra]); XCTAssertNil(sizes[extra]); XCTAssertTrue(incomplete.contains(extra))
            return CleanResult(id: "fixture", trashed: true)
        })
        model.toggleDuplicate(extra, group: group)
        XCTAssertEqual(model.sizeState(extra), .unavailable); XCTAssertEqual(model.basketBytes, 0)
        model.trash()
        for _ in 0..<100 where model.working { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    @MainActor func testLeavingAgainCancelsTheQueuedPostRestoreRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = SpaceLens.scan(root.path), calls = CountedReads()
        let began = expectation(description: "old scan"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = SpaceLensModel(root: root.path, cache: root.appendingPathComponent("cache.json"), measure: { _, _, _ in
            _ = calls.next(); began.fulfill(); _ = release.wait(timeout: .now() + 5); return old
        })
        model.scan(); await fulfillment(of: [began], timeout: 2)
        model.invalidateAfterRestore([root.path + "/restored"])
        model.scan(); model.stop()
        release.signal()
        for _ in 0..<100 where model.scanning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(calls.count, 1); XCTAssertNil(model.tree)
    }
    @MainActor func testRestoreInvalidationDiscardsOldScanAndWaitsBeforeRequestedReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache.json"), old = SpaceLens.scan(root.path)
        SpaceLens.save(old, to: cache)
        let calls = CountedReads(), began = expectation(description: "old scan"), next = expectation(description: "fresh scan")
        let release = DispatchSemaphore(value: 0); defer { release.signal() }
        let model = SpaceLensModel(root: root.path, cache: cache, measure: { path, token, _ in
            if calls.next() == 1 { began.fulfill(); _ = release.wait(timeout: .now() + 5); return old }
            next.fulfill(); return SpaceLens.scan(path, cancellation: token)
        })
        model.scan(); await fulfillment(of: [began], timeout: 2)
        let restored = root.appendingPathComponent("Downloads/restored.bin")
        try Data(repeating: 37, count: 2 << 20).write(to: restored)
        model.invalidateAfterRestore([restored.path])
        XCTAssertNil(model.tree); XCTAssertTrue(model.scanning); XCTAssertTrue(model.stopping)
        for _ in 0..<100 { model.scan() }
        XCTAssertEqual(calls.count, 1)
        release.signal(); await fulfillment(of: [next], timeout: 2)
        for _ in 0..<100 where model.scanning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(model.tree?.folder(root.appendingPathComponent("Downloads").path)?.children.contains { $0.path == restored.path } == true)
        XCTAssertTrue(SpaceLens.cached(root: root.path, from: cache)?.folder(root.appendingPathComponent("Downloads").path)?.children.contains { $0.path == restored.path } == true)
    }

    @MainActor func testRestoreInvalidationWithoutReopenDoesNotStartHiddenReplacementOrRepublishCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache.json"), old = SpaceLens.scan(root.path)
        SpaceLens.save(old, to: cache)
        let began = expectation(description: "old scan"), release = DispatchSemaphore(value: 0), calls = CountedReads()
        defer { release.signal() }
        let model = SpaceLensModel(root: root.path, cache: cache, measure: { _, _, _ in
            _ = calls.next(); began.fulfill(); _ = release.wait(timeout: .now() + 5); return old
        })
        model.scan(); await fulfillment(of: [began], timeout: 2)
        model.invalidateAfterRestore([root.path + "/restored"])
        release.signal()
        for _ in 0..<100 where model.scanning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(model.tree); XCTAssertEqual(calls.count, 1)
        XCTAssertNil(SpaceLens.cached(root: root.path, from: cache))
    }

    @MainActor func testRestoreInvalidationClearsSelectionAndPreservesUnrelatedTree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Downloads/item"), cache = root.appendingPathComponent("cache.json")
        try Data("fixture".utf8).write(to: file)
        SpaceLens.save(SpaceLens.scan(root.path), to: cache)
        let model = SpaceLensModel(root: root.path, cache: cache)
        model.toggle(file.path, bytes: 7); model.outcome = "old outcome"
        model.invalidateAfterRestore(["/unrelated-restoration"])
        XCTAssertNotNil(model.tree); XCTAssertEqual(model.basket.count, 1)
        model.invalidateAfterRestore([file.path])
        XCTAssertNil(model.tree); XCTAssertTrue(model.basket.isEmpty); XCTAssertNil(model.outcome)
    }
    @MainActor func testCancelledDuplicateWorkerRetainsSlotAndCoalescesReopenRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let began = expectation(description: "first duplicate worker"), second = expectation(description: "replacement worker")
        let release = DispatchSemaphore(value: 0); defer { release.signal() }
        let calls = CountedReads()
        let model = SpaceLensModel(root: root.path, cache: root.appendingPathComponent("cache.json"), searchDuplicates: { roots, _, _ in
            XCTAssertTrue(roots.allSatisfy { $0.hasPrefix(root.path + "/") })
            let n = calls.next()
            if n == 1 { began.fulfill(); _ = release.wait(timeout: .now() + 5) } else { second.fulfill() }
            return [DuplicateGroup(hash: "fixture", size: 1, paths: ["/scan\(n)/a", "/scan\(n)/b"], reclaimable: 1)]
        })
        model.findDuplicates(); await fulfillment(of: [began], timeout: 2)
        model.stopDuplicates(); XCTAssertTrue(model.findingDuplicates); XCTAssertTrue(model.stoppingDuplicates)
        for _ in 0..<100 { model.findDuplicates() }
        XCTAssertEqual(calls.count, 1)
        release.signal(); await fulfillment(of: [second], timeout: 2)
        for _ in 0..<100 where model.findingDuplicates { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(calls.count, 2); XCTAssertFalse(model.stoppingDuplicates)
        XCTAssertEqual(model.duplicates?.first?.paths, ["/scan2/a", "/scan2/b"])
    }

    @MainActor func testStoppedDuplicateReadDoesNotPublishItsLateResult() async throws {
        let began = expectation(description: "duplicate worker"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = SpaceLensModel(searchDuplicates: { _, _, _ in
            began.fulfill(); _ = release.wait(timeout: .now() + 5)
            return [DuplicateGroup(hash: "fixture", size: 1, paths: ["/a", "/b"], reclaimable: 1)]
        })
        model.findDuplicates(); await fulfillment(of: [began], timeout: 2)
        model.stopDuplicates(); XCTAssertTrue(model.findingDuplicates)
        release.signal()
        for _ in 0..<100 where model.findingDuplicates { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.findingDuplicates); XCTAssertNil(model.duplicates)
    }

    @MainActor func testRemovalCancelsQueuedDuplicateRefreshBeforeItCanRepopulateRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Downloads/a"); try Data("fixture".utf8).write(to: file)
        let began = expectation(description: "duplicate worker"), release = DispatchSemaphore(value: 0), calls = CountedReads()
        defer { release.signal() }
        let model = SpaceLensModel(root: root.path, cache: root.appendingPathComponent("cache.json"), remove: { _, _, _, _, _, _ in CleanResult(id: "fixture", trashed: true) }, searchDuplicates: { _, _, _ in
            _ = calls.next(); began.fulfill(); _ = release.wait(timeout: .now() + 5)
            return [DuplicateGroup(hash: "fixture", size: 1, paths: [file.path, "/b"], reclaimable: 1)]
        })
        model.findDuplicates(); await fulfillment(of: [began], timeout: 2)
        model.findDuplicates(); model.toggle(file.path, bytes: 7); model.trash()
        for _ in 0..<100 where model.working { try await Task.sleep(nanoseconds: 10_000_000) }
        release.signal()
        for _ in 0..<100 where model.findingDuplicates { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(calls.count, 1); XCTAssertNil(model.duplicates)
    }

    private final class CountedReads: @unchecked Sendable {
        let lock = NSLock(); private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    @MainActor func testConfirmedManualRemovalPinsSelectionAndBlocksQuitUntilWorkerReturns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("Downloads/item").path
        try Data("fixture".utf8).write(to: URL(fileURLWithPath: path))
        let expected = try XCTUnwrap(ManualRemoval.reviewIdentity(path))
        let began = expectation(description: "moving"), release = DispatchSemaphore(value: 0), calls = Calls()
        defer { release.signal() }
        let model = SpaceLensModel(root: root.path, cache: root.appendingPathComponent("cache.json"), remove: { paths, _, _, _, identities, _ in
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
        let model = SpaceLensModel(root: root.path, cache: root.appendingPathComponent("cache.json"), remove: { paths, sizes, home, incomplete, identities, required in
            ManualRemoval.trash(paths, sizes: sizes, home: home, incompletePaths: incomplete, reviewIdentities: identities, requiredIdentities: required,
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
