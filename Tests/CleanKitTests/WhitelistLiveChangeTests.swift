@testable import CleanKit
import AgentCore
import Foundation
import XCTest

final class WhitelistLiveChangeTests: XCTestCase {
    var home = ""
    var a: String { home + "/Library/Caches/com.example.dynamic/a" }
    var b: String { home + "/Library/Caches/com.example.dynamic/b" }
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        for path in [a,b] {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data("owned fixture".utf8).write(to: URL(fileURLWithPath: path))
        }
        try FileManager.default.createDirectory(at: Whitelist.url(home: home).deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func list(_ text: String) throws {
        let file = Whitelist.url(home: home)
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func move(_ path: String) throws -> URL {
        let destination = URL(fileURLWithPath: home + "/.Trash/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: path, toPath: destination.path); return destination
    }
    func testCleanerHonorsProtectionAddedAfterTheFirstMove() throws {
        let item = CleanItem(id: "fixture", category: .devCaches, title: "fixture", safety: .review, paths: [a,b])
        var moves = 0
        let result = Cleaner.clean(item, mode: .trash, guard: Guard(home: home), scannedAt: nil, processTable: .init(entries: []), batchID: nil,
            operations: .init(trash: { path in
                let destination = try self.move(path); moves += 1
                if moves == 1 { try self.list(self.b + "\n") }
                return destination
            }, remove: { _ in XCTFail("Trash only") }))
        XCTAssertEqual(result.removed, [a]); XCTAssertEqual(result.whitelisted, [b]); XCTAssertTrue(FS.exists(b))
    }
    func testAppDataRemovalHonorsProtectionAddedAfterTheFirstMove() throws {
        var result = CleanResult(id: "fixture", trashed: true), moves = 0
        AppUninstaller.trash([a,b], bundleIDs: ["com.example.dynamic"], sizes: [:], home: home, processes: { .init(entries: []) }, into: &result, move: { path in
            let destination = try self.move(path); moves += 1
            if moves == 1 { try self.list(self.b + "\n") }
            return destination
        })
        XCTAssertEqual(result.removed, [a]); XCTAssertEqual(result.whitelisted, [b]); XCTAssertTrue(FS.exists(b))
    }
    func testCleanerStopsRemainingPathsWhenWhitelistBecomesInvalid() throws {
        let item = CleanItem(id: "fixture", category: .devCaches, title: "fixture", safety: .review, paths: [a,b])
        let result = Cleaner.clean(item, mode: .trash, guard: Guard(home: home), scannedAt: nil, processTable: .init(entries: []), batchID: nil,
            operations: .init(trash: { path in
                let destination = try self.move(path); try self.list("relative/protected\n"); return destination
            }, remove: { _ in XCTFail("Trash only") }))
        XCTAssertEqual(result.removed, [a]); XCTAssertNotNil(result.failed[b]); XCTAssertTrue(FS.exists(b))
        let restored = try TrashBatches.restore(id: XCTUnwrap(result.trashBatchID), home: home)
        XCTAssertEqual(restored.items.first?.status, "restored"); XCTAssertTrue(FS.exists(a))
    }
    func testAppRemovalStopsRemainingPathsWhenWhitelistBecomesInvalid() throws {
        var result = CleanResult(id: "fixture", trashed: true)
        AppUninstaller.trash([a,b], bundleIDs: ["com.example.dynamic"], sizes: [:], home: home, processes: { .init(entries: []) }, into: &result, move: { path in
            let destination = try self.move(path); try self.list("relative/protected\n"); return destination
        })
        XCTAssertEqual(result.removed, [a]); XCTAssertNotNil(result.failed[b]); XCTAssertTrue(FS.exists(b))
        XCTAssertNotNil(result.trashBatchID)
    }
    func commandFixture(_ next: String) throws -> (CleanItem, String) {
        let source = home + "/next-whitelist", marker = home + "/second-command-ran"
        try Data(next.utf8).write(to: URL(fileURLWithPath: source))
        let item = CleanItem(id: "fixture-command", category: .devCaches, title: "fixture", safety: .risky,
            commands: [["/bin/cp", source, Whitelist.url(home: home).path], ["/usr/bin/touch", marker]])
        return (item, marker)
    }
    func testChangedProtectionStopsRemainingToolCommands() throws {
        let (item, marker) = try commandFixture("~/keep\n")
        let result = Cleaner.clean(item, mode: .permanent, guard: Guard(home: home), processTable: .init(entries: []))
        XCTAssertFalse(FS.exists(marker)); XCTAssertNotNil(result.failed["whitelist"])
        XCTAssertEqual(result.removed.count, 1); XCTAssertEqual(result.outcome, "partial")
    }
    func testCommentsWithoutProtectionChangesDoNotDisableToolCommands() throws {
        let (item, marker) = try commandFixture("# comment only\n")
        let result = Cleaner.clean(item, mode: .permanent, guard: Guard(home: home), processTable: .init(entries: []))
        XCTAssertTrue(FS.exists(marker)); XCTAssertTrue(result.failed.isEmpty); XCTAssertEqual(result.removed.count, 2)
    }
    func testChangedProtectionSkipsPostCleanupHookWithoutLosingMovedResult() throws {
        let marker = home + "/post-hook-ran"
        let item = CleanItem(id: "fixture", category: .devCaches, title: "fixture", safety: .review, paths: [a], afterClean: ["/usr/bin/touch " + Shell.quote(marker)])
        let result = Cleaner.clean(item, mode: .trash, guard: Guard(home: home), scannedAt: nil, processTable: .init(entries: []), batchID: nil,
            operations: .init(trash: { path in
                let destination = try self.move(path); try self.list("~/keep\n"); return destination
            }, remove: { _ in XCTFail("Trash only") }))
        XCTAssertEqual(result.removed, [a]); XCTAssertFalse(FS.exists(marker))
        XCTAssertNotNil(result.failed["afterClean/whitelist"]); XCTAssertNotNil(result.trashBatchID)
    }

}
