@testable import CleanKit
import AgentCore
import Darwin
import Foundation
import XCTest

final class WhitelistReadTrustTests: XCTestCase {
    var home = ""
    var location: URL { Whitelist.url(home: home) }
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func write(_ text: String) throws {
        try Data(text.utf8).write(to: location)
        XCTAssertEqual(chmod(location.path, 0o600), 0)
    }
    func testFIFOWithoutPeerDoesNotHangInspectionOrEditing() throws {
        XCTAssertEqual(mkfifo(location.path, 0o600), 0)
        let start = Date()
        XCTAssertThrowsError(try Whitelist.load(home: home))
        XCTAssertThrowsError(try Whitelist.add(["~/keep"], home: home))
        XCTAssertThrowsError(try Whitelist.remove(["~/keep"], home: home))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        var st = stat(); XCTAssertEqual(lstat(location.path, &st), 0); XCTAssertEqual(st.st_mode & S_IFMT, S_IFIFO)
    }
    func testPathReplacementAfterReadDoesNotPublishStaleProtection() throws {
        try write("~/old\n")
        XCTAssertThrowsError(try Whitelist.read(home: home, afterRead: {
            try Data("~/new\n".utf8).write(to: self.location, options: .atomic)
        }))
        XCTAssertEqual(try Whitelist.loadForRemoval(home: home).entries, [home + "/new"])
    }
    func testSameInodeRewriteAfterReadDoesNotPublishStaleProtection() throws {
        try write("~/old\n"); let identity = FileIdentity.of(location.path)
        XCTAssertThrowsError(try Whitelist.read(home: home, afterRead: {
            let file = try FileHandle(forWritingTo: self.location); try file.write(contentsOf: Data("~/new\n".utf8)); try file.close()
        }))
        XCTAssertEqual(FileIdentity.of(location.path), identity)
        XCTAssertEqual(try Whitelist.loadForRemoval(home: home).entries, [home + "/new"])
    }
    func testParentLinkCannotTurnConfiguredWhitelistIntoAnAbsentList() throws {
        let folder = location.deletingLastPathComponent(), moved = folder.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: folder, to: moved)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: moved)
        XCTAssertThrowsError(try Whitelist.load(home: home))
        XCTAssertNotNil(Whitelist.refusal(home + "/Downloads/item", home: home))
    }
    func testInvalidRowsRemainInspectableButBlockRemovalAndCachedScan() throws {
        try write("~/keep\nrelative/protected-path\n")
        let inspected = try Whitelist.load(home: home)
        XCTAssertEqual(inspected.entries, [home + "/keep"]); XCTAssertEqual(inspected.rejected.map(\.line), [2])
        XCTAssertThrowsError(try Whitelist.loadForRemoval(home: home))
        XCTAssertNotNil(Whitelist.refusal(home + "/Downloads/item", home: home, whitelist: inspected))
        let item = home + "/Downloads/item"
        try FileManager.default.createDirectory(atPath: home + "/Downloads", withIntermediateDirectories: true)
        try Data("own".utf8).write(to: URL(fileURLWithPath: item))
        let result = ManualRemoval.trash([item], sizes: [:], home: home, openFiles: { .init(holders: []) }, move: { _ in XCTFail("Invalid protection must stop removal"); throw NSError(domain: "fixture", code: 1) })
        XCTAssertTrue(result.removed.isEmpty); XCTAssertNotNil(result.failed[item]); XCTAssertTrue(FS.exists(item))
        var report = ScanReport(items: [.init(id: "fixture", category: .system, title: "fixture", safety: .safe, paths: [item])], denied: [], started: Date(), duration: 0)
        report.applyWhitelist(home: home)
        XCTAssertNotNil(report.whitelistError); XCTAssertFalse(report.items[0].cleanable)
    }
    func trashBatch() throws -> (String, TrashBatch.Entry) {
        let trash = home + "/.Trash/item", original = home + "/Downloads/item"
        for dir in [".Trash", "Downloads"] { try FileManager.default.createDirectory(atPath: home + "/" + dir, withIntermediateDirectories: true) }
        try Data("owned trash sample".utf8).write(to: URL(fileURLWithPath: trash))
        let id = UUID().uuidString, entry = TrashBatch.Entry(original: original, destination: trash, identity: try XCTUnwrap(FileIdentity.of(trash)), bytes: 18)
        try TrashBatches.append(entry, id: id, home: home)
        return (id, try XCTUnwrap(TrashBatches.load(id, home: home).entries.first))
    }
    func testInvalidWhitelistStopsRecordedPermanentRemoval() throws {
        let (id, entry) = try trashBatch(); try write("relative/protected-path\n")
        XCTAssertNotNil(TrashBatches.emptyRefusal(entry, home: home))
        XCTAssertThrowsError(try TrashBatches.empty(id, home: home))
        XCTAssertTrue(FS.exists(entry.destination))
    }
    func testRecordedPermanentRemovalKeepsOriginalAndTrashWhitelistMatches() throws {
        let (id, entry) = try trashBatch()
        for path in [entry.original, entry.destination] {
            try write(path + "\n")
            let result = try TrashBatches.empty(id, home: home)
            XCTAssertTrue(result.removed.isEmpty); XCTAssertEqual(result.whitelisted, [entry.destination])
            XCTAssertTrue(FS.exists(entry.destination))
        }
    }
    func testInvalidWhitelistDoesNotBlockRestoringOriginalFiles() throws {
        let (id, entry) = try trashBatch(); try write("relative/protected-path\n")
        let result = try TrashBatches.restore(id: id, home: home)
        XCTAssertEqual(result.items.first?.status, "restored")
        XCTAssertEqual(try String(contentsOfFile: entry.original), "owned trash sample")
        XCTAssertFalse(FS.exists(entry.destination))
    }

    func testCRLFDoesNotMergeProtectionAndDiagnosticLineNumbers() throws {
        try write("~/keep\r\n# comment\r\nrelative/path\r\n")
        let inspected = try Whitelist.load(home: home)
        XCTAssertEqual(inspected.entries, [home + "/keep"])
        XCTAssertEqual(inspected.rejected.map(\.line), [3])
    }
    func testLeadingUTF8BOMDoesNotDropTheFirstProtection() throws {
        try write("\u{FEFF}~/keep\r\n")
        let whitelist = try Whitelist.loadForRemoval(home: home)
        XCTAssertEqual(whitelist.entries, [home + "/keep"]); XCTAssertTrue(whitelist.protects(home + "/keep/data"))
    }
}
