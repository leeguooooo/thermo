@testable import CleanKit
@testable import ThermoApp
import Foundation
import XCTest

final class DuplicateSelectionRefreshTests: XCTestCase {
    var root: URL!
    var keeper: String { root.appendingPathComponent("Downloads/keeper").path }
    var extra: String { root.appendingPathComponent("Downloads/extra").path }
    var manual: String { root.appendingPathComponent("Downloads/manual").path }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        for path in [keeper, extra, manual] { try Data("owned fixture".utf8).write(to: URL(fileURLWithPath: path)) }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func group() throws -> DuplicateGroup {
        .init(hash: "fixture", size: 13, paths: [keeper, extra], reclaimable: 4,
              reviewIdentities: [keeper: try XCTUnwrap(ManualRemoval.reviewIdentity(keeper)), extra: try XCTUnwrap(ManualRemoval.reviewIdentity(extra))],
              privateBytes: [extra: 4], reclaimableState: .complete)
    }
    @MainActor func testRescanDropsOnlyDuplicateDerivedSelectionsBeforeReaderStarts() async throws {
        let group = try group(), began = expectation(description: "rescan"), release = DispatchSemaphore(value: 0), calls = Calls()
        defer { release.signal() }
        let model = SpaceLensModel(root: root.path, cache: root.appendingPathComponent("cache"), searchDuplicates: { _, _, _ in
            if calls.next() == 2 { began.fulfill(); _ = release.wait(timeout: .now() + 5) }
            return .init(groups: [group])
        })
        model.findDuplicates(); try await idle(model)
        model.toggleDuplicate(extra, group: group); model.toggle(manual, bytes: 13)
        model.findDuplicates(); await fulfillment(of: [began], timeout: 2)
        XCTAssertNil(model.basket[extra]); XCTAssertEqual(model.basket[manual], 13)
        XCTAssertNotNil(model.outcome)
        model.pickAllButOldest(); XCTAssertNil(model.basket[extra], "old rows cannot add selections while comparing")
        release.signal(); try await idle(model)
    }
    @MainActor func testBulkSelectionAddsRetainedProofToAnAlreadySelectedManualFile() async throws {
        let group = try group(), moved = expectation(description: "reviewed removal")
        let extra = extra, keeper = keeper
        let model = SpaceLensModel(root: root.path, cache: root.appendingPathComponent("cache"), remove: { paths, sizes, _, _, identities, required in
            XCTAssertEqual(paths, [extra]); XCTAssertEqual(sizes[extra], 4)
            XCTAssertEqual(identities[extra], group.reviewIdentities?[extra])
            XCTAssertEqual(required[keeper], group.reviewIdentities?[keeper]); moved.fulfill()
            return CleanResult(id: "fixture", trashed: true)
        }, searchDuplicates: { _, _, _ in .init(groups: [group]) })
        model.findDuplicates(); try await idle(model)
        model.toggle(extra, bytes: 999999); model.pickAllButOldest(); model.trash()
        await fulfillment(of: [moved], timeout: 2)
        for _ in 0..<100 where model.working { try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor func testKeepOldestRefusesASelectedKeeperWithoutChangingManualChoices() async throws {
        let group = try group()
        let model = SpaceLensModel(root: root.path, cache: root.appendingPathComponent("cache"), searchDuplicates: { _, _, _ in .init(groups: [group]) })
        model.findDuplicates(); try await idle(model)
        model.toggle(keeper, bytes: 13); model.toggle(extra, bytes: 13)
        let before = model.basket
        model.pickAllButOldest()
        XCTAssertEqual(model.basket, before); XCTAssertTrue(model.outcomeIsWarning); XCTAssertNotNil(model.outcome)
        model.toggleDuplicate(keeper, group: group); model.pickAllButOldest()
        XCTAssertNil(model.basket[keeper]); XCTAssertEqual(model.basket[extra], 4)
        XCTAssertFalse(model.outcomeIsWarning); XCTAssertNil(model.outcome)
    }
    @MainActor func testSelectedContainingFolderBlocksDuplicateChoiceBeforeConfirmation() async throws {
        let folder = root.appendingPathComponent("Downloads/selected-folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let movedKeeper = folder.appendingPathComponent("keeper").path
        try FileManager.default.moveItem(atPath: keeper, toPath: movedKeeper)
        let group = DuplicateGroup(hash: "fixture", size: 13, paths: [movedKeeper, extra], reclaimable: 4,
            reviewIdentities: [movedKeeper: try XCTUnwrap(ManualRemoval.reviewIdentity(movedKeeper)), extra: try XCTUnwrap(ManualRemoval.reviewIdentity(extra))], privateBytes: [extra: 4])
        let model = SpaceLensModel(root: root.path, cache: root.appendingPathComponent("cache"), searchDuplicates: { _, _, _ in .init(groups: [group]) })
        model.findDuplicates(); try await idle(model)
        model.toggle(folder.path, bytes: 13); model.toggleDuplicate(extra, group: group)
        XCTAssertNil(model.basket[extra]); XCTAssertEqual(model.basket[folder.path], 13); XCTAssertTrue(model.outcomeIsWarning)
    }
    @MainActor func testOldGroupActionCannotReapplyAnOutdatedPrivateSize() async throws {
        let old = try group(), calls = Calls()
        var updated = old; updated.reclaimable = 8; updated.privateBytes = [extra: 8]
        let fresh = updated
        let model = SpaceLensModel(root: root.path, cache: root.appendingPathComponent("cache"), searchDuplicates: { _, _, _ in .init(groups: [calls.next() == 1 ? old : fresh]) })
        model.findDuplicates(); try await idle(model)
        model.findDuplicates(); try await idle(model)
        model.toggleDuplicate(extra, group: old); XCTAssertTrue(model.basket.isEmpty); XCTAssertTrue(model.outcomeIsWarning)
        model.toggleDuplicate(extra, group: fresh); XCTAssertEqual(model.basket[extra], 8)
    }
    @MainActor func testBulkReviewDoesNotApplyEarlierGroupsWhenALaterGroupChanged() async throws {
        let first = try group(), c = root.appendingPathComponent("Downloads/c"), d = root.appendingPathComponent("Downloads/d")
        for file in [c, d] { try Data("second owned group".utf8).write(to: file) }
        let second = DuplicateGroup(hash: "other", size: 18, paths: [c.path, d.path], reclaimable: 4,
            reviewIdentities: [c.path: try XCTUnwrap(ManualRemoval.reviewIdentity(c.path)), d.path: try XCTUnwrap(ManualRemoval.reviewIdentity(d.path))], privateBytes: [d.path: 4])
        let model = SpaceLensModel(root: root.path, cache: root.appendingPathComponent("cache"), searchDuplicates: { _, _, _ in .init(groups: [first, second]) })
        model.findDuplicates(); try await idle(model)
        try Data("changed second group".utf8).write(to: d)
        model.pickAllButOldest(); XCTAssertTrue(model.basket.isEmpty); XCTAssertTrue(model.outcomeIsWarning)
    }

    @MainActor private func idle(_ model: SpaceLensModel) async throws {
        for _ in 0..<200 where model.findingDuplicates { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.findingDuplicates)
    }
    private final class Calls: @unchecked Sendable {
        let lock = NSLock(); private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }
}
