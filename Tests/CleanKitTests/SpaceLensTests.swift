@testable import CleanKit
import XCTest

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
}
