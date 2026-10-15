import XCTest
import Foundation
import Darwin
@testable import AgentCore

final class OperationJournalReadTests: XCTestCase {
    var home = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(at: OperationJournal.url(home: home).deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: home) }
    func record() -> OperationRecord { .init(feature: "fixture", action: "test", items: [.init(target: "/owned", status: "done")]) }

    func testMissingJournalIsCompleteButDirectoryAtJournalPathIsNotEmptyHistory() throws {
        XCTAssertTrue(OperationJournal.readReport(home: home).complete)
        let url = OperationJournal.url(home: home)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let report = OperationJournal.readReport(home: home)
        XCTAssertFalse(report.complete); XCTAssertTrue(report.records.isEmpty)
        XCTAssertFalse(report.issues.isEmpty)
    }

    func testLinkedLiveJournalIsRefusedWhileVerifiedRotatedRecordsRemainVisible() throws {
        let saved = record(); OperationJournal.record(saved, home: home)
        let url = OperationJournal.url(home: home)
        try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent("operations.1.jsonl"))
        let outside = URL(fileURLWithPath: home).appendingPathComponent("outside")
        try Data("private fixture must not be read".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        let report = OperationJournal.readReport(home: home)
        XCTAssertFalse(report.complete); XCTAssertEqual(report.records.map(\.id), [saved.id])
        XCTAssertFalse(report.issues.joined().contains("private fixture"))
    }

    func testDamagedLinesAndOversizedFilesAreExplicitlyIncomplete() throws {
        let saved = record(); OperationJournal.record(saved, home: home)
        let url = OperationJournal.url(home: home)
        let file = try FileHandle(forWritingTo: url); try file.seekToEnd()
        try file.write(contentsOf: Data("not JSON\n{\"torn\":".utf8)); try file.close()
        let partial = OperationJournal.readReport(home: home)
        XCTAssertEqual(partial.records.map(\.id), [saved.id]); XCTAssertFalse(partial.complete)
        XCTAssertTrue(partial.issues.joined().contains("2 damaged"))
        let large = try FileHandle(forWritingTo: url)
        try large.truncate(atOffset: UInt64(OperationJournal.maxBytes * 2 + 1)); try large.close()
        let oversized = OperationJournal.readReport(home: home)
        XCTAssertFalse(oversized.complete); XCTAssertTrue(oversized.records.isEmpty)
    }

    func testFIFOWithoutPeerDoesNotBlockEitherReadingOrRecording() async throws {
        let url = OperationJournal.url(home: home)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        let path = home
        let readDone = expectation(description: "read refuses FIFO")
        DispatchQueue.global().async {
            XCTAssertFalse(OperationJournal.readReport(home: path).complete)
            readDone.fulfill()
        }
        await fulfillment(of: [readDone], timeout: 1)
        // If a regression blocked open(), let the waiting reader finish instead of leaking it.
        let writer = open(url.path, O_WRONLY | O_NONBLOCK); if writer >= 0 { close(writer) }
        let writeDone = expectation(description: "record refuses FIFO")
        let sample = record()
        DispatchQueue.global().async { OperationJournal.record(sample, home: path); writeDone.fulfill() }
        await fulfillment(of: [writeDone], timeout: 1)
        let reader = open(url.path, O_RDONLY | O_NONBLOCK); if reader >= 0 { close(reader) }
    }

    func testBusyJournalIsUnknownInsteadOfWaitingOrClaimingNoOperations() throws {
        OperationJournal.record(record(), home: home)
        let fd = open(OperationJournal.url(home: home).path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { flock(fd, LOCK_UN); close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let report = OperationJournal.readReport(home: home)
        XCTAssertFalse(report.complete); XCTAssertTrue(report.issues.joined().contains("busy"))
    }

    func testRotationNeverRecursivelyDeletesAnUnexpectedGenerationDirectory() throws {
        OperationJournal.record(record(), home: home)
        let live = OperationJournal.url(home: home)
        let large = try FileHandle(forWritingTo: live)
        try large.truncate(atOffset: UInt64(OperationJournal.maxBytes)); try large.close()
        let generation = live.deletingLastPathComponent().appendingPathComponent("operations.2.jsonl")
        try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: false)
        let marker = generation.appendingPathComponent("must-survive")
        let bytes = Data("owned unexpected fixture".utf8); try bytes.write(to: marker)
        OperationJournal.record(record(), home: home)
        XCTAssertEqual(try? Data(contentsOf: marker), bytes)
    }

    func testRotationDoesNotReplaceAnUnexpectedGenerationSymlink() throws {
        OperationJournal.record(record(), home: home)
        let live = OperationJournal.url(home: home)
        let large = try FileHandle(forWritingTo: live)
        try large.truncate(atOffset: UInt64(OperationJournal.maxBytes)); try large.close()
        let generation = live.deletingLastPathComponent().appendingPathComponent("operations.2.jsonl")
        let outside = URL(fileURLWithPath: home).appendingPathComponent("keep")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: generation, withDestinationURL: outside)
        OperationJournal.record(record(), home: home)
        XCTAssertEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: generation.path), outside.path)
        XCTAssertEqual(try Data(contentsOf: outside), Data("keep".utf8))
    }

    func testWriterDoesNotCreateARecordLargerThanTheReaderCanAccept() {
        let huge = OperationRecord(feature: "fixture", action: "test", items: [.init(target: String(repeating: "x", count: OperationJournal.maxBytes * 2), status: "done")])
        OperationJournal.record(huge, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: OperationJournal.url(home: home).path))
    }
}
