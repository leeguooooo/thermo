@testable import CleanKit
@testable import AgentCore
import Darwin
import Foundation
import XCTest

final class ManualRemovalReviewTests: XCTestCase {
    var home = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: home + "/Downloads", withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func file(_ name: String, text: String = "original") throws -> String {
        let path = home + "/Downloads/" + name
        try Data(text.utf8).write(to: URL(fileURLWithPath: path)); return path
    }
    func move(_ path: String) throws -> URL {
        try FileManager.default.createDirectory(atPath: home + "/.Trash", withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: home + "/.Trash/" + UUID().uuidString)
        try FileManager.default.moveItem(atPath: path, toPath: url.path); return url
    }
    func testRetainedCopyChangedBetweenMovesStopsRemainingCopies() throws {
        let keeper = try file("keeper"), a = try file("a"), b = try file("b")
        let identity = try XCTUnwrap(ManualRemoval.reviewIdentity(keeper))
        let result = ManualRemoval.trash([a, b], sizes: [:], home: home, requiredIdentities: [keeper: identity], openFiles: { .init(holders: []) }, move: { path in
            let destination = try self.move(path)
            try Data("unique replacement".utf8).write(to: URL(fileURLWithPath: keeper))
            return destination
        })
        XCTAssertEqual(result.removed, [a]); XCTAssertNotNil(result.failed[b])
        XCTAssertTrue(FileManager.default.fileExists(atPath: b))
    }
    func testSelectingRetainedCopyOrItsParentPreventsAllMoves() throws {
        try FileManager.default.createDirectory(atPath: home + "/Downloads/sub", withIntermediateDirectories: true)
        let keeper = try file("keeper"), a = try file("a")
        let identity = try XCTUnwrap(ManualRemoval.reviewIdentity(keeper))
        for selected in [[a, keeper], [home + "/Downloads/sub", a]] {
            let required = selected.contains(keeper) ? keeper : try file("sub/keeper")
            let token = required == keeper ? identity : try XCTUnwrap(ManualRemoval.reviewIdentity(required))
            let result = ManualRemoval.trash(selected, sizes: [:], home: home, requiredIdentities: [required: token], openFiles: { .init(holders: []) }, move: { _ in XCTFail("Must keep comparison reference"); return URL(fileURLWithPath: "/unused") })
            XCTAssertTrue(result.removed.isEmpty)
        }
    }
    func testReplacementAfterSelectionIsNotMoved() throws {
        let path = try file("a")
        let identity = try XCTUnwrap(ManualRemoval.reviewIdentity(path))
        try FileManager.default.moveItem(atPath: path, toPath: path + "-kept")
        _ = try file("a", text: "replacement")
        let result = ManualRemoval.trash([path], sizes: [path: 8], home: home, reviewIdentities: [path: identity], openFiles: { .init(holders: []) }, move: move)
        XCTAssertTrue(result.removed.isEmpty); XCTAssertNotNil(result.failed[path])
        XCTAssertEqual(try String(contentsOfFile: path), "replacement")
    }
    func testSameInodeRewriteAfterReviewIsNotMoved() throws {
        let path = try file("a"), identity = try XCTUnwrap(ManualRemoval.reviewIdentity(home + "/Downloads/a"))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: 0); try handle.write(contentsOf: Data("changed bytes".utf8)); try handle.close()
        let result = ManualRemoval.trash([path], sizes: [path: 8], home: home, reviewIdentities: [path: identity], openFiles: { .init(holders: []) }, move: move)
        XCTAssertTrue(result.removed.isEmpty); XCTAssertNotNil(result.failed[path])
    }
    func testItemChangedWhileOpenFilesAreReadIsNotMoved() throws {
        let path = try file("a")
        let result = ManualRemoval.trash([path], sizes: [path: 8], home: home, openFiles: {
            try? Data("changed during query".utf8).write(to: URL(fileURLWithPath: path))
            return .init(holders: [])
        }, move: move)
        XCTAssertTrue(result.removed.isEmpty); XCTAssertNotNil(result.failed[path])
    }
    func testOpenFileInventoryIsCheckedForEachMoveAndPartialRecoveryIsRecorded() throws {
        let a = try file("a"), b = try file("b")
        let physical = try XCTUnwrap(realpath(b, nil)); defer { free(physical) }
        let physicalPath = String(cString: physical)
        var calls = 0
        let result = ManualRemoval.trash([a, b], sizes: [a: 8, b: 8], home: home, openFiles: {
            calls += 1
            return calls == 1 ? .init(holders: []) : .init(holders: [.init(path: physicalPath, pid: 42, name: "fixture")])
        }, move: move)
        XCTAssertEqual(calls, 2); XCTAssertEqual(result.removed, [a]); XCTAssertNotNil(result.failed[b])
        let batch = try TrashBatches.load(try XCTUnwrap(result.trashBatchID), home: home)
        XCTAssertEqual(batch.entries.map(\.original), [a]); XCTAssertTrue(FileManager.default.fileExists(atPath: b))
    }
    func testMissingReviewIdentityAndUnknownOpenFileInventoryCannotAuthorizeMove() throws {
        let path = try file("a")
        let missing = ManualRemoval.trash([path], sizes: [:], home: home, reviewIdentities: [:], openFiles: { .init(holders: []) }, move: move)
        XCTAssertTrue(missing.removed.isEmpty); XCTAssertNotNil(missing.failed[path])
        let unknown = ManualRemoval.trash([path], sizes: [:], home: home, openFiles: { nil }, move: move)
        XCTAssertTrue(unknown.removed.isEmpty); XCTAssertNotNil(unknown.failed[path])
    }
    func testUnchangedIncompleteSizeMoveCanBeRestoredWithoutLosingBytes() throws {
        let path = try file("a")
        let identity = try XCTUnwrap(ManualRemoval.reviewIdentity(path))
        let result = ManualRemoval.trash([path, path], sizes: [path: 0], home: home, incompletePaths: [path],
            reviewIdentities: [path: identity], openFiles: { .init(holders: []) }, move: move)
        XCTAssertEqual(result.removed, [path]); XCTAssertEqual(result.bytesIncomplete, true)
        let restored = try TrashBatches.restore(id: try XCTUnwrap(result.trashBatchID), home: home)
        XCTAssertEqual(restored.items.first?.status, "restored"); XCTAssertEqual(try String(contentsOfFile: path), "original")
    }
    func testParentReplacementIsDetectedEvenWhenTheSelectedInodeStillMatches() throws {
        let a = home + "/Downloads/A", b = home + "/Downloads/B"
        try FileManager.default.createDirectory(atPath: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: b, withIntermediateDirectories: true)
        try Data("same inode".utf8).write(to: URL(fileURLWithPath: a + "/item"))
        try FileManager.default.linkItem(atPath: a + "/item", toPath: b + "/item")
        let identity = try XCTUnwrap(ManualRemoval.reviewIdentity(a + "/item"))
        let inode = FileIdentity.of(a + "/item")
        try FileManager.default.moveItem(atPath: a, toPath: a + "-kept")
        try FileManager.default.moveItem(atPath: b, toPath: a)
        XCTAssertEqual(FileIdentity.of(a + "/item"), inode)
        let result = ManualRemoval.trash([a + "/item"], sizes: [:], home: home,
            reviewIdentities: [a + "/item": identity], openFiles: { .init(holders: []) }, move: move)
        XCTAssertTrue(result.removed.isEmpty); XCTAssertFalse(result.failed.isEmpty)
    }
    func testWhitelistAddedDuringAnOpenFileQueryIsAppliedBeforeMove() throws {
        let path = try file("kept")
        let result = ManualRemoval.trash([path], sizes: [:], home: home, openFiles: {
            _ = try? Whitelist.add([path], home: self.home)
            return .init(holders: [])
        }, move: move)
        XCTAssertEqual(result.whitelisted, [path]); XCTAssertTrue(result.removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
}
