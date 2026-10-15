@testable import CleanKit
import XCTest
import Darwin

final class SpaceLensTests: XCTestCase {
    var dir: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("space-\(UUID().uuidString)").resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    func write(_ rel: String, mb: Int, seed: UInt8 = 1) throws {
        let path = dir + "/" + rel
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: mb << 20)
        for i in stride(from: 0, to: bytes.count, by: 4096) { bytes[i] = seed &+ UInt8(truncatingIfNeeded: i >> 12) }
        try Data(bytes).write(to: URL(fileURLWithPath: path))
    }

    func testOneWalkKeepsEveryBigFolderBiggestFirst() throws {
        try write("a/big.bin", mb: 3)
        try write("a/deep/x/y/z.bin", mb: 2)
        try write("b/one.bin", mb: 1)
        try "tiny".write(toFile: dir + "/b/tiny.txt", atomically: true, encoding: .utf8)
        let t = SpaceLens.scan(dir)
        XCTAssertTrue(t.complete)
        let top = try XCTUnwrap(t.folder(dir))
        XCTAssertEqual(top.children.map(\.name), ["a", "b"])
        XCTAssertEqual(top.entry.files, 4)
        // Nested folders are kept for drilling in, without walking again.
        XCTAssertNotNil(t.folder(dir + "/a/deep/x/y"))
        XCTAssertEqual(t.trail(to: dir + "/a/deep/x").map(\.name), [(dir as NSString).lastPathComponent, "a", "deep", "x"])
        let b = try XCTUnwrap(t.folder(dir + "/b"))
        XCTAssertEqual(b.otherCount, 1, "the tiny file is summed, not listed")
        let a = try XCTUnwrap(t.folder(dir + "/a"))
        XCTAssertEqual(a.entry.bytes, a.children.reduce(0) { $0 + $1.bytes } + a.otherBytes)
    }

    func testRemovingUpdatesEveryFolderAbove() throws {
        try write("a/big.bin", mb: 3)
        try write("a/deep/z.bin", mb: 2)
        let t = SpaceLens.scan(dir)
        let before = try XCTUnwrap(t.folder(dir)).entry.bytes
        let deep = try XCTUnwrap(t.folder(dir + "/a")?.children.first { $0.name == "deep" })
        let after = t.removing([dir + "/a/deep"])
        XCTAssertNil(after.folder(dir + "/a/deep"))
        XCTAssertEqual(after.folder(dir)?.entry.bytes, before - deep.bytes)
        XCTAssertEqual(after.folder(dir + "/a")?.children.map(\.name), ["big.bin"])
    }

    func testDuplicatesAreFoundByContentAndOldestComesFirst() throws {
        try write("one/photo.jpg", mb: 2, seed: 7)
        try write("two/copy of photo.jpg", mb: 2, seed: 7)
        try write("two/same size, other bytes.jpg", mb: 2, seed: 9)
        let old = Date(timeIntervalSinceNow: -86400 * 30)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir + "/two/copy of photo.jpg")
        let groups = Duplicates.find(in: [dir])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.paths, [dir + "/two/copy of photo.jpg", dir + "/one/photo.jpg"])
    }

    func testHandPickedRemovalRefusesWhatMustStay() {
        let home = "/Users/someone"
        XCTAssertNil(ManualRemoval.refusal(home + "/Downloads/old.dmg", home: home))
        XCTAssertNil(ManualRemoval.refusal(home + "/github.com/project/node_modules", home: home))
        XCTAssertNotNil(ManualRemoval.refusal(home + "/Documents", home: home))
        XCTAssertNotNil(ManualRemoval.refusal(home, home: home))
        XCTAssertNotNil(ManualRemoval.refusal(home + "/Library", home: home))
        XCTAssertNotNil(ManualRemoval.refusal(home + "/.ssh/id_ed25519", home: home))
        XCTAssertNotNil(ManualRemoval.refusal(home + "/Library/Mobile Documents/x", home: home))
        XCTAssertNotNil(ManualRemoval.refusal(home + "/Pictures/Photos Library.photoslibrary/originals/a.heic", home: home))
        XCTAssertNotNil(ManualRemoval.refusal(home + "/github.com/project/.git", home: home))
        XCTAssertNotNil(ManualRemoval.refusal("/Applications/Safari.app", home: home))
        XCTAssertNotNil(ManualRemoval.refusal(home + "/Downloads/../.ssh", home: home))
    }

    func testUnreadableSmallFolderStaysVisibleAndMakesAncestorsPartial() throws {
        try XCTSkipIf(getuid() == 0, "requires ordinary user permissions")
        try write("readable/file.bin", mb: 2)
        let locked = dir + "/locked"
        try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked) }
        let tree = SpaceLens.scan(dir)
        XCTAssertFalse(tree.complete)
        XCTAssertTrue(tree.unreadable.contains(locked))
        let top = try XCTUnwrap(tree.folder(dir))
        XCTAssertEqual(top.entry.effectiveSizeState, .incomplete)
        XCTAssertGreaterThan(top.entry.bytes, 0)
        let child = try XCTUnwrap(top.children.first { $0.path == locked })
        XCTAssertEqual(child.effectiveSizeState, .unavailable)
        XCTAssertEqual(tree.folder(locked)?.entry.effectiveSizeState, .unavailable)
    }

    func testCancellationKeepsKnownBytesAndUnvisitedChildrenInTheReturnedTree() throws {
        try write("known.bin", mb: 2)
        try write("queued/other.bin", mb: 2)
        let cancellation = ScanCancellation()
        let tree = SpaceLens.scan(dir, cancellation: cancellation) { _ in cancellation.cancel() }
        XCTAssertFalse(tree.complete)
        XCTAssertEqual(tree.cancelled, true)
        let top = try XCTUnwrap(tree.folder(dir))
        XCTAssertGreaterThan(top.entry.bytes, 0)
        XCTAssertEqual(top.entry.effectiveSizeState, .incomplete)
        XCTAssertEqual(top.children.first { $0.name == "known.bin" }?.effectiveSizeState, .complete)
        XCTAssertEqual(top.children.first { $0.name == "queued" }?.effectiveSizeState, .unavailable)
    }

    func testPrecancelledScanStillReturnsAnUnknownRoot() throws {
        let token = ScanCancellation(); token.cancel()
        let tree = SpaceLens.scan(dir, cancellation: token)
        XCTAssertFalse(tree.complete)
        XCTAssertEqual(tree.folder(dir)?.entry.effectiveSizeState, .unavailable)
        XCTAssertNotNil(tree.folder(dir))
    }

    func testIncompleteAndLegacyTreesCannotBeReusedAsCompleteCaches() throws {
        let url = URL(fileURLWithPath: dir + "/cache.json")
        let complete = SpaceLens.scan(dir)
        SpaceLens.save(complete, to: url)
        XCTAssertNotNil(SpaceLens.cached(root: dir, from: url))
        var legacy = complete; legacy.sizeVersion = nil
        var partial = complete; partial.folders[dir]?.entry.sizeState = .unavailable
        for invalid in [legacy, partial] {
            try JSONEncoder().encode(invalid).write(to: url)
            XCTAssertNil(SpaceLens.cached(root: dir, from: url))
        }
    }
}
