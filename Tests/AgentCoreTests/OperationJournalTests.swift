import XCTest
@testable import AgentCore

final class OperationJournalTests: XCTestCase {
    func testLastAppendFinishesPendingOperationEvenInTheSameSecond() {
        let started = OperationRecord(id: "same-operation", time: Date(timeIntervalSince1970: 100), feature: "apps", action: "update",
            items: [.init(target: "fixture", status: "partial")])
        var finished = started
        finished.outcome = "succeeded"
        finished.items = [.init(target: "fixture", status: "done")]
        OperationJournal.record(started, home: home)
        OperationJournal.record(finished, home: home)
        let read = OperationJournal.read(home: home)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.outcome, "succeeded")
    }
    var home: String!
    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "journal-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: home) }

    func testRecordsAreReadBackNewestFirst() {
        let a = OperationRecord(time: Date(timeIntervalSince1970: 100), feature: "clean", action: "trash", subject: "xcode",
                                items: [.init(target: "/x/a", bytes: 10, status: "done")], undo: .init(kind: "trashBatch", ref: "B"))
        let b = OperationRecord(time: Date(timeIntervalSince1970: 200), feature: "agents", action: "fix",
                                items: [.init(target: "hook", status: "failed", detail: "boom")])
        OperationJournal.record(a, home: home)
        OperationJournal.record(b, home: home)
        let read = OperationJournal.read(home: home)
        XCTAssertEqual(read.map(\.id), [b.id, a.id])
        XCTAssertEqual(read.last, a)
        XCTAssertEqual(OperationJournal.find(String(a.id.prefix(8)), home: home)?.id, a.id)
        let mode = try? FileManager.default.attributesOfItem(atPath: OperationJournal.url(home: home).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testOutcomeAndSizeAreDerivedHonestly() {
        let mixed = OperationRecord(feature: "clean", action: "delete", items: [
            .init(target: "/a", bytes: 5, status: "done"), .init(target: "/b", bytes: nil, status: "done"),
            .init(target: "/c", status: "failed")])
        XCTAssertEqual(mixed.outcome, "partial")
        XCTAssertEqual(mixed.bytes, 5)
        XCTAssertEqual(mixed.bytesIncomplete, true)
        XCTAssertEqual(OperationRecord(feature: "x", action: "y", items: [.init(target: "/a", status: "failed")]).outcome, "failed")
        let unknown = OperationRecord(feature: "x", action: "y", items: [.init(target: "/a", status: "done")])
        XCTAssertNil(unknown.bytes)
        XCTAssertEqual(unknown.outcome, "succeeded")
    }

    func testDamagedLinesAreSkipped() throws {
        let good = OperationRecord(feature: "clean", action: "trash", items: [.init(target: "/a", status: "done")])
        OperationJournal.record(good, home: home)
        let handle = try FileHandle(forWritingTo: OperationJournal.url(home: home))
        handle.seekToEndOfFile(); handle.write(Data("{torn json\n".utf8)); try handle.close()
        let later = OperationRecord(feature: "clean", action: "trash", items: [.init(target: "/b", status: "done")])
        OperationJournal.record(later, home: home)
        XCTAssertEqual(Set(OperationJournal.read(home: home).map(\.id)), [good.id, later.id])
    }

    func testRotationKeepsTwoGenerations() {
        let big = String(repeating: "x", count: 400_000)
        var ids: [String] = []
        for n in 0..<40 {
            let r = OperationRecord(time: Date(timeIntervalSince1970: Double(n)), feature: "clean", action: "trash",
                                    items: [.init(target: big, status: "done")])
            ids.append(r.id)
            OperationJournal.record(r, home: home)
        }
        let dir = OperationJournal.url(home: home).deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(names.contains("operations.1.jsonl"))
        XCTAssertTrue(names.contains("operations.2.jsonl"))
        XCTAssertFalse(names.contains("operations.3.jsonl"))
        let read = OperationJournal.read(home: home)
        XCTAssertEqual(read.first?.id, ids.last)
        XCTAssertLessThan(read.count, 40)
        XCTAssertGreaterThan(read.count, 10)
    }

    func testEmptyRecordsAreNotWritten() {
        OperationJournal.record(OperationRecord(feature: "clean", action: "trash", outcome: "succeeded", items: []), home: home)
        XCTAssertTrue(OperationJournal.read(home: home).isEmpty)
    }
}
