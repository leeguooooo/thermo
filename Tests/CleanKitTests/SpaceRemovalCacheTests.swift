@testable import CleanKit
import Foundation
import Darwin
import XCTest

final class SpaceRemovalCacheTests: XCTestCase {
    func entry(_ path: String, bytes: Int64, dir: Bool = false) -> SpaceEntry {
        SpaceEntry(path: path, name: (path as NSString).lastPathComponent, isDir: dir, bytes: bytes, files: 1, sizeState: .complete)
    }
    func tree(_ folder: SpaceFolder, others: [String: SpaceFolder] = [:], large: [LargeFile] = []) -> SpaceTree {
        var folders = others; folders["/fixture"] = folder
        return SpaceTree(root: "/fixture", scanned: Date(), folders: folders, large: large, unreadable: [], complete: true, duration: 0, sizeVersion: 1)
    }
    func testOmittedLargeFileIsRemovedAndItsKnownAggregateIsAdjusted() throws {
        let root = SpaceFolder(entry: entry("/fixture", bytes: 1000, dir: true), children: [entry("/fixture/kept", bytes: 300)], otherBytes: 700, otherCount: 2)
        let before = tree(root, large: [LargeFile(path: "/fixture/omitted", bytes: 200, modified: Date())])
        let after = before.removing(["/fixture/omitted"])
        XCTAssertTrue(after.large.isEmpty); XCTAssertEqual(after.folder("/fixture")?.entry.bytes, 800)
        XCTAssertEqual(after.folder("/fixture")?.otherBytes, 500); XCTAssertEqual(after.folder("/fixture")?.otherCount, 1)
        XCTAssertTrue(after.complete)
    }
    func testUnknownOmittedExtentDoesNotTurnOldOverestimateIntoALowerBound() {
        let root = SpaceFolder(entry: entry("/fixture", bytes: 1000, dir: true), children: [entry("/fixture/kept", bytes: 300)], otherBytes: 700, otherCount: 2)
        let after = tree(root).removing(["/fixture/unknown"])
        XCTAssertFalse(after.complete)
        XCTAssertEqual(after.folder("/fixture")?.entry.bytes, 300)
        XCTAssertEqual(after.folder("/fixture")?.entry.effectiveSizeState, .incomplete)
        XCTAssertEqual(after.folder("/fixture")?.otherBytes, 0)
    }
    func testUnknownNestedExtentRebuildsAncestorsAndKeepsUnrelatedAggregate() {
        let sub = SpaceFolder(entry: entry("/fixture/sub", bytes: 600, dir: true), children: [entry("/fixture/sub/kept", bytes: 200)], otherBytes: 400, otherCount: 2)
        let root = SpaceFolder(entry: entry("/fixture", bytes: 1000, dir: true), children: [sub.entry], otherBytes: 400, otherCount: 1)
        let after = tree(root, others: ["/fixture/sub": sub]).removing(["/fixture/sub/unknown"])
        XCTAssertEqual(after.folder("/fixture/sub")?.entry.bytes, 200)
        XCTAssertEqual(after.folder("/fixture")?.entry.bytes, 600)
        XCTAssertEqual(after.folder("/fixture")?.otherBytes, 400)
        XCTAssertFalse(after.complete)
    }
    func testKnownRemovalInsideAnOmittedDirectoryAdjustsAncestorAggregate() {
        let sub = SpaceFolder(entry: entry("/fixture/sub", bytes: 700, dir: true), children: [entry("/fixture/sub/gone", bytes: 200), entry("/fixture/sub/kept", bytes: 500)], otherBytes: 0, otherCount: 0)
        let root = SpaceFolder(entry: entry("/fixture", bytes: 1000, dir: true), children: [entry("/fixture/visible", bytes: 300)], otherBytes: 700, otherCount: 1)
        let after = tree(root, others: ["/fixture/sub": sub]).removing(["/fixture/sub/gone"])
        XCTAssertEqual(after.folder("/fixture")?.entry.bytes, 800)
        XCTAssertEqual(after.folder("/fixture")?.otherBytes, 500)
        XCTAssertEqual(after.folder("/fixture")?.otherCount, 1)
    }
    func testUnknownRemovalInsideAnOmittedDirectoryKeepsKnownSurvivorsVisible() {
        let sub = SpaceFolder(entry: entry("/fixture/sub", bytes: 700, dir: true), children: [entry("/fixture/sub/kept", bytes: 200)], otherBytes: 500, otherCount: 1)
        let root = SpaceFolder(entry: entry("/fixture", bytes: 1000, dir: true), children: [entry("/fixture/visible", bytes: 300)], otherBytes: 700, otherCount: 1)
        let after = tree(root, others: ["/fixture/sub": sub]).removing(["/fixture/sub/unknown"])
        XCTAssertFalse(after.complete)
        XCTAssertEqual(after.folder("/fixture")?.entry.bytes, 500)
        XCTAssertEqual(after.folder("/fixture")?.otherBytes, 0)
        XCTAssertTrue(after.folder("/fixture")?.children.contains { $0.path == "/fixture/sub" && $0.effectiveSizeState == .incomplete } == true)
    }
    func testMixedKnownAndUnknownRemovalDoesNotSubtractAnOmittedBranchTwice() {
        let sub = SpaceFolder(entry: entry("/fixture/sub", bytes: 700, dir: true), children: [entry("/fixture/sub/known", bytes: 200), entry("/fixture/sub/kept", bytes: 200)], otherBytes: 300, otherCount: 1)
        let root = SpaceFolder(entry: entry("/fixture", bytes: 1400, dir: true), children: [entry("/fixture/visible", bytes: 300)], otherBytes: 1100, otherCount: 2)
        let after = tree(root, others: ["/fixture/sub": sub]).removing(["/fixture/sub/known", "/fixture/sub/unknown"])
        XCTAssertFalse(after.complete)
        XCTAssertEqual(after.folder("/fixture")?.otherBytes, 400)
        XCTAssertEqual(after.folder("/fixture")?.entry.bytes, 900)
        XCTAssertEqual(after.folder("/fixture/sub")?.entry.bytes, 200)
    }
    func testCacheInvalidationUnlinksOnlyAnOwnedRegularFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cache.json")
        try Data("cache".utf8).write(to: file)
        XCTAssertTrue(SpaceLens.invalidateCache(at: file)); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: file.appendingPathComponent("child"))
        XCTAssertFalse(SpaceLens.invalidateCache(at: file))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathComponent("child").path))
    }
    func testCacheReadRejectsFIFOWithoutWaitingForAWriter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("cache.json")
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertNil(SpaceLens.cached(root: "/fixture", from: file))
    }
    func testParentSymlinkCannotRedirectCacheReadWriteOrInvalidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = external.appendingPathComponent("cache.json")
        try Data("must remain".utf8).write(to: file)
        let link = root.appendingPathComponent("redirect")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: external.path)
        let redirected = link.appendingPathComponent("cache.json")
        let value = tree(SpaceFolder(entry: entry("/fixture", bytes: 0, dir: true), children: [], otherBytes: 0, otherCount: 0))
        XCTAssertNil(SpaceLens.cached(root: "/fixture", from: redirected))
        XCTAssertFalse(SpaceLens.invalidateCache(at: redirected))
        SpaceLens.save(value, to: redirected)
        XCTAssertEqual(try String(contentsOf: file), "must remain")
    }
}
