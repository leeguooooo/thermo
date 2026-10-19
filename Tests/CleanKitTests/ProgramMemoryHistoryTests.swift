import Foundation
import XCTest
import AgentCore
@testable import CleanKit

final class ProgramMemoryHistoryTests: XCTestCase {
    func testAppendRetainsSortedValidRecordsAndExactExpiryBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("history.jsonl")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func record(_ age: Double) -> ProgramMemoryRecord {
            ProgramMemoryRecord(t: now.addingTimeInterval(-age), programs: ["owned": 300_000], names: ["owned": "Owned"])
        }
        let recent = record(60), boundary = record(PulseHistory.keep), expired = record(PulseHistory.keep + 1)
        var bytes = Data()
        for r in [recent, expired, boundary] {
            bytes.append(try PulseHistory.encoder.encode(r)); bytes.append(10)
        }
        bytes.append(Data("bad json\n{\"t\":1800000000}\n".utf8))
        try bytes.write(to: url)
        let history = ProgramMemoryHistory(url: url), next = record(0)
        history.append(next, now: now)
        XCTAssertEqual(history.records(since: .distantPast), [boundary, recent, next])
    }

    func testExistingIdentityPayloadAndUnknownFieldsArePreservedWithoutReencoding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("history.jsonl")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var old = ProgramMemoryRecord(t: now.addingTimeInterval(-60), programs: ["owned": 300_000], names: ["owned": "Owned"])
        old.identities = ["owned": (1...200).map {
            ProcessIdentity(pid: Int32($0), uid: 501, started: now.addingTimeInterval(-1000), executable: "/owned/tool")
        }]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: PulseHistory.encoder.encode(old)) as? [String: Any])
        object["futureField"] = "preserve"
        let original = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try original.write(to: url) // Missing final newline is also accepted.
        let history = ProgramMemoryHistory(url: url)
        let next = ProgramMemoryRecord(t: now, programs: [:], names: [:])
        history.append(next, now: now)
        let lines = try Data(contentsOf: url).split(separator: 10)
        XCTAssertEqual(Data(try XCTUnwrap(lines.first)), original)
        XCTAssertEqual(history.records(since: .distantPast), [old, next])
        history.append(next, now: now)
        XCTAssertEqual(history.records(since: .distantPast), [old, next, next])
    }
}
