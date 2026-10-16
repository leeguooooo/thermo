import AgentCore
import Darwin
import Foundation
import XCTest
@testable import CleanKit

final class TrashBatchRecordTests: XCTestCase {
    var home = "", id = "", location: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        id = UUID().uuidString
        try FileManager.default.createDirectory(at: TrashBatches.root(home: home), withIntermediateDirectories: true)
        location = try TrashBatches.url(id, home: home)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func header(_ created: Int = 0) -> Data { Data("{\"id\":\"\(id)\",\"created\":\(created)}\n".utf8) }
    func entry() throws -> TrashBatch.Entry {
        let trash = URL(fileURLWithPath: home).appendingPathComponent(".Trash/item")
        try FileManager.default.createDirectory(at: trash.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("owned fixture".utf8).write(to: trash)
        return TrashBatch.Entry(original: home + "/Downloads/item", destination: trash.path, identity: try XCTUnwrap(FileIdentity.of(trash.path)), bytes: 13)
    }
    func testFIFOWithoutPeerDoesNotBlockReadAppendOrSynchronize() throws {
        let sample = try entry()
        XCTAssertEqual(mkfifo(location.path, 0o600), 0)
        let start = Date()
        XCTAssertThrowsError(try TrashBatches.load(id, home: home))
        XCTAssertThrowsError(try TrashBatches.append(sample, id: id, home: home))
        XCTAssertThrowsError(try TrashBatches.synchronize(id, home: home))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        var st = stat(); XCTAssertEqual(lstat(location.path, &st), 0); XCTAssertEqual(st.st_mode & S_IFMT, S_IFIFO)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sample.destination)), Data("owned fixture".utf8))
    }
    func testLinkedAndDirectoryRecordsAreRefusedWithoutChangingTheirContents() throws {
        let sample = try entry(), target = URL(fileURLWithPath: home).appendingPathComponent("target")
        try header().write(to: target)
        for kind in ["symlink", "hardlink", "directory"] {
            switch kind {
            case "symlink": try FileManager.default.createSymbolicLink(at: location, withDestinationURL: target)
            case "hardlink": try FileManager.default.linkItem(at: target, to: location)
            default: try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
            }
            XCTAssertThrowsError(try TrashBatches.load(id, home: home), kind)
            XCTAssertThrowsError(try TrashBatches.append(sample, id: id, home: home), kind)
            XCTAssertThrowsError(try TrashBatches.synchronize(id, home: home), kind)
            XCTAssertEqual(try Data(contentsOf: target), header())
            try FileManager.default.removeItem(at: location)
        }
    }
    func testOversizedSparseRecordIsRejectedBeforeReadingOrWriting() throws {
        let sample = try entry()
        FileManager.default.createFile(atPath: location.path, contents: nil)
        let file = try FileHandle(forWritingTo: location); try file.truncate(atOffset: UInt64(TrashBatches.maximumRecordBytes + 1)); try file.close()
        XCTAssertThrowsError(try TrashBatches.load(id, home: home))
        XCTAssertThrowsError(try TrashBatches.append(sample, id: id, home: home))
        XCTAssertThrowsError(try TrashBatches.synchronize(id, home: home))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int, TrashBatches.maximumRecordBytes + 1)
    }
    func testBusyRecordIsUnknownAndIsNotAppended() throws {
        let sample = try entry(); try header().write(to: location)
        let fd = open(location.path, O_RDWR | O_CLOEXEC); XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0); defer { flock(fd, LOCK_UN) }
        XCTAssertThrowsError(try TrashBatches.load(id, home: home))
        XCTAssertThrowsError(try TrashBatches.append(sample, id: id, home: home))
        XCTAssertThrowsError(try TrashBatches.synchronize(id, home: home))
        XCTAssertEqual(try Data(contentsOf: location), header())
    }
    func testReplacementAfterReadCannotAuthorizeTheOldSnapshot() throws {
        try header().write(to: location)
        let old = location.appendingPathExtension("old")
        XCTAssertThrowsError(try TrashBatches.load(id, home: home, afterRead: {
            try FileManager.default.moveItem(at: self.location, to: old)
            try self.header().write(to: self.location)
        })) { XCTAssertTrue($0.localizedDescription.contains("changed")) }
        XCTAssertEqual(try Data(contentsOf: old), header())
        XCTAssertEqual(try TrashBatches.load(id, home: home).entries.count, 0)
    }
    func testSameInodeRewriteAfterReadCannotAuthorizeTheOldSnapshot() throws {
        try header().write(to: location)
        let before = FileIdentity.of(location.path)
        XCTAssertThrowsError(try TrashBatches.load(id, home: home, afterRead: {
            let file = try FileHandle(forWritingTo: self.location)
            try file.write(contentsOf: self.header(1)); try file.close()
        })) { XCTAssertTrue($0.localizedDescription.contains("changed")) }
        XCTAssertEqual(FileIdentity.of(location.path), before)
        XCTAssertEqual(try TrashBatches.load(id, home: home).created, Date(timeIntervalSinceReferenceDate: 1))
    }
    func testTruncatedJournalRemainsAnErrorRatherThanAnEmptyBatch() throws {
        try Data(header().dropLast()).write(to: location)
        XCTAssertThrowsError(try TrashBatches.load(id, home: home))
    }
}
