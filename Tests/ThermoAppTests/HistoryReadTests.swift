import XCTest
import Foundation
import AgentCore
@testable import CleanKit
@testable import ThermoApp

final class HistoryReadTests: XCTestCase {
    final class Reader: @unchecked Sendable {
        let reports: [OperationJournal.ReadReport]
        let gates: [Int: (XCTestExpectation, DispatchSemaphore)]
        private let lock = NSLock()
        private var calls = 0, active = 0, peak = 0
        init(_ reports: [OperationJournal.ReadReport], gates: [Int: (XCTestExpectation, DispatchSemaphore)] = [:]) { self.reports = reports; self.gates = gates }
        func read() -> OperationJournal.ReadReport {
            lock.lock(); let index = calls; calls += 1; active += 1; peak = max(peak, active); lock.unlock()
            if let (began, release) = gates[index] { began.fulfill(); _ = release.wait(timeout: .now() + 5) }
            lock.lock(); active -= 1; lock.unlock()
            return reports[min(index, reports.count - 1)]
        }
        var stats: (calls: Int, peak: Int) { lock.lock(); defer { lock.unlock() }; return (calls, peak) }
    }
    func record(_ id: String, time: Double = 1) -> OperationRecord {
        .init(id: id, time: Date(timeIntervalSince1970: time), feature: "fixture", action: "test", items: [.init(target: "/fixture", status: "done")])
    }
    @MainActor func finish(_ model: HistoryModel) async {
        for _ in 0..<200 where model.reading || model.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.reading); XCTAssertFalse(model.busy)
    }

    @MainActor func testRefreshStormUsesOneReaderAndNeverPublishesTheSupersededSnapshot() async {
        let first = expectation(description: "first read"), second = expectation(description: "coalesced read")
        let releaseFirst = DispatchSemaphore(value: 0), releaseSecond = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal(); releaseSecond.signal() }
        let reader = Reader([.init(records: [record("old")]), .init(records: [record("new")])], gates: [0: (first, releaseFirst), 1: (second, releaseSecond)])
        let model = HistoryModel(reader: { reader.read() })
        model.load(); await fulfillment(of: [first], timeout: 2)
        for _ in 0..<1000 { model.load() }
        XCTAssertEqual(reader.stats.calls, 1); XCTAssertTrue(model.reading)
        releaseFirst.signal(); await fulfillment(of: [second], timeout: 2)
        XCTAssertTrue(model.records.isEmpty); XCTAssertFalse(model.loaded)
        releaseSecond.signal(); await finish(model)
        XCTAssertEqual(model.records.map(\.id), ["new"])
        XCTAssertEqual(reader.stats.calls, 2); XCTAssertEqual(reader.stats.peak, 1)
    }

    @MainActor func testRestoreDuringReadQueuesFreshHistoryWithoutAnOverlappingWorker() async {
        let began = expectation(description: "old read"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let reader = Reader([.init(records: [record("before")]), .init(records: [record("restored")])], gates: [0: (began, release)])
        let model = HistoryModel(reader: { reader.read() }, restoreBatch: { id in
            TrashRestore(id: id, dryRun: false, items: [.init(original: "/fixture", destination: "/trash/fixture", bytes: 1, status: "restored")])
        }, didRestore: { _ in })
        model.load(); await fulfillment(of: [began], timeout: 2)
        let entry = OperationRecord(feature: "fixture", action: "remove", items: [.init(target: "/fixture", status: "done")], undo: .init(kind: "trashBatch", ref: UUID().uuidString))
        model.restore(entry)
        for _ in 0..<200 where model.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.busy); XCTAssertEqual(reader.stats.calls, 1)
        release.signal(); await finish(model)
        XCTAssertEqual(model.records.map(\.id), ["restored"]); XCTAssertEqual(reader.stats.peak, 1)
    }

    @MainActor func testUnreadableHistoryRetainsKnownRecordsUntilACompleteRefreshArrives() async {
        let reader = Reader([.init(records: [record("known")]), .init(records: [], issues: ["fixture denied"]), .init(records: [record("fresh")]), .init(records: [])])
        let model = HistoryModel(reader: { reader.read() })
        model.load(); await finish(model)
        model.load(); await finish(model)
        XCTAssertEqual(model.records.map(\.id), ["known"]); XCTAssertTrue(model.loaded)
        XCTAssertTrue(model.readIssue?.contains("fixture denied") == true)
        model.load(); await finish(model)
        XCTAssertEqual(model.records.map(\.id), ["fresh"]); XCTAssertNil(model.readIssue)
        model.load(); await finish(model)
        XCTAssertTrue(model.records.isEmpty); XCTAssertNil(model.readIssue)
    }

    @MainActor func testPartialReadUpdatesKnownIDsWithoutDroppingPreviouslyVerifiedRecords() async {
        let reader = Reader([.init(records: [record("same"), record("retained", time: 0)]), .init(records: [record("same", time: 2), record("new", time: 3)], issues: ["rotated file denied"])])
        let model = HistoryModel(reader: { reader.read() })
        model.load(); await finish(model); model.load(); await finish(model)
        XCTAssertEqual(model.records.map(\.id), ["new", "same", "retained"])
        XCTAssertEqual(model.records.first(where: { $0.id == "same" })?.time, Date(timeIntervalSince1970: 2))
        XCTAssertNotNil(model.readIssue)
    }
}
