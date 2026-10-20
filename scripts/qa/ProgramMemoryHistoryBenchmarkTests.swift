// Copied into Tests/CleanKitTests only inside an isolated QA snapshot.
import Foundation
import XCTest
import Darwin
import AgentCore
@testable import CleanKit

final class ProgramMemoryHistoryBenchmarkTests: XCTestCase {
    func testAppendProbe() throws {
        let mode = ProcessInfo.processInfo.environment["THERMO_HISTORY_PROBE_MODE"] ?? ""
        guard ["baseline", "copied-lines", "optimized"].contains(mode) else { throw XCTSkip("Explicit QA mode required") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("owned-history.jsonl")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let history = ProgramMemoryHistory(url: url)
        func record(_ index: Int) -> ProgramMemoryRecord {
            var r = ProgramMemoryRecord(t: now.addingTimeInterval(Double(index - 288) * 300),
                                       programs: [:], names: [:])
            r.identities = [:]
            for program in 0..<48 {
                let key = "owned-\(program)"
                r.programs[key] = 300_000 + index
                r.names[key] = key
                r.identities?[key] = (0..<8).map { part in
                    ProcessIdentity(pid: Int32(program * 8 + part + 1), uid: 501,
                                    started: now.addingTimeInterval(-100_000),
                                    executable: "/owned/fixture/\(program)/tool")
                }
            }
            return r
        }
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        for index in 0..<288 {
            try autoreleasepool {
                var line = try PulseHistory.encoder.encode(record(index)); line.append(10)
                try handle.write(contentsOf: line)
            }
        }
        try handle.close()
        let fixtureBytes = try Data(contentsOf: url).count
        let next = record(288)
        var before = rusage(), after = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
        let start = ProcessInfo.processInfo.systemUptime
        if mode == "optimized" { history.append(next, now: now) }
        else if mode == "copied-lines" {
            // Previous optimization, retained as a third comparison arm.
            let existing = try Data(contentsOf: url)
            let kept: [(time: Date, line: Data)] = existing.split(separator: 10).compactMap { line in
                guard let r = try? PulseHistory.decoder.decode(ProgramMemoryRecord.self, from: Data(line)),
                      now.timeIntervalSince(r.t) <= PulseHistory.keep else { return nil }
                return (r.t, Data(line))
            }.sorted { $0.time < $1.time }
            var data = Data()
            for entry in kept { data.append(entry.line); data.append(10) }
            if let line = try? PulseHistory.encoder.encode(next) { data.append(line); data.append(10) }
            try data.write(to: url, options: .atomic)
        }
        else {
            // Exact previous append algorithm, on this owned fixture only.
            var kept = history.records(since: .distantPast).filter { now.timeIntervalSince($0.t) <= PulseHistory.keep }
            kept.append(next)
            var data = Data()
            for r in kept {
                if let line = try? PulseHistory.encoder.encode(r) { data.append(line); data.append(10) }
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
        func cpu(_ r: rusage) -> Double {
            Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
        }
        // Readback occurs after capturing peak so validation allocations are excluded.
        let actual = history.records(since: .distantPast)
        XCTAssertEqual(actual.count, 289)
        for (i, r) in actual.enumerated() { XCTAssertEqual(r, record(i)) }
        let metrics: [String: Any] = ["mode": mode, "recordsBefore": 288, "programsPerRecord": 48,
            "identitiesPerProgram": 8, "fixtureBytes": fixtureBytes, "wallSeconds": elapsed,
            "cpuSeconds": cpu(after) - cpu(before), "peakRSSBytesBefore": before.ru_maxrss,
            "peakRSSBytesAfter": after.ru_maxrss, "readbackRecords": actual.count,
            "allRecordsAndIdentitiesEqual": true]
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
        print("THERMO_HISTORY_PROBE " + String(decoding: data, as: UTF8.self))
    }
}
