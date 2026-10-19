import XCTest
@testable import AgentDoctor

final class CumulativeTokenSnapshotTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    func parser() -> ToolUsageParser { ToolUsageParser(since: start, until: start.addingTimeInterval(100)) }
    func event(_ seconds: Double, _ usage: [String: Any]) -> [String: Any] {
        ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds)),
         "payload": ["type": "token_count", "info": ["total_token_usage": usage,
            "last_token_usage": ["input_tokens": 999999, "output_tokens": 999999]]]]
    }
    func counters(_ input: Int, output: Int = 20) -> [String: Any] {
        ["input_tokens": input, "output_tokens": output, "cached_input_tokens": input - 1,
         "reasoning_output_tokens": 10, "cache_write_input_tokens": 0]
    }
    func testLatestSnapshotIsNotSummedWithOtherEventsOrRequestRecords() throws {
        var p = parser()
        p.consume(event(1, counters(100)), host: "codex", session: "private-session")
        p.consume(event(2, counters(150)), host: "codex", session: "private-session")
        p.consume(event(2, counters(150)), host: "codex", session: "private-session")
        p.consume(event(1, counters(100)), host: "codex", session: "private-session")
        let report = p.report(), row = try XCTUnwrap(report.cumulativeTokenSnapshots?.first)
        XCTAssertEqual(report.cumulativeTokenSnapshots?.count, 1)
        XCTAssertEqual(row.inputTokens, 150); XCTAssertEqual(row.cachedInputTokens, 149)
        XCTAssertEqual(row.cacheWriteInputTokens, 0); XCTAssertEqual(row.reasoningOutputTokens, 10)
        XCTAssertTrue(report.sessionTokens.isEmpty); XCTAssertTrue(report.tools.isEmpty)
        XCTAssertEqual(report.coverage.unsupportedUsageRecords, 0)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("private-session"))
    }
    func testForksStaySeparateAndCounterDecreaseUsesLatestTimestamp() throws {
        var p = parser()
        p.consume(event(3, counters(100)), host: "codex", session: "parent")
        p.consume(event(4, counters(100)), host: "codex", session: "fork")
        p.consume(event(5, counters(50)), host: "codex", session: "parent")
        let rows = try XCTUnwrap(p.report().cumulativeTokenSnapshots)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.compactMap(\.inputTokens).sorted(), [50, 100])
    }
    func testConflictingLatestTimestampStaysUnknownUntilNewerObservation() throws {
        for sequence in [[100, 150, 100], [150, 100, 150]] {
            var p = parser()
            for input in sequence { p.consume(event(4, counters(input)), host: "codex", session: "s") }
            let row = try XCTUnwrap(p.report().cumulativeTokenSnapshots?.first)
            XCTAssertTrue(row.conflictingLatestRecords)
            XCTAssertNil(row.inputTokens); XCTAssertNil(row.outputTokens); XCTAssertNil(row.cachedInputTokens)
            p.consume(event(5, counters(200)), host: "codex", session: "s")
            XCTAssertEqual(p.report().cumulativeTokenSnapshots?.first?.inputTokens, 200)
            XCTAssertEqual(p.report().cumulativeTokenSnapshots?.first?.conflictingLatestRecords, false)
        }
    }
    func testWindowAndNativeEventShapeAreRequired() throws {
        var p = parser()
        p.consume(event(-1, counters(100)), host: "codex", session: "s")
        p.consume(event(101, counters(100)), host: "codex", session: "s")
        var wrong = event(5, counters(100)); wrong["type"] = "response_item"
        p.consume(wrong, host: "codex", session: "s")
        XCTAssertTrue(try XCTUnwrap(p.report().cumulativeTokenSnapshots).isEmpty)
        XCTAssertEqual(p.report().coverage.unsupportedUsageRecords, 0)
    }
    func testInvalidRequiredCountersNeverBecomeZeroAndOptionalFieldsRemainUnknown() throws {
        var p = parser()
        for bad in [true, -1, 1.5, "100"] as [Any] {
            p.consume(event(4, ["input_tokens": bad, "output_tokens": 1]), host: "codex", session: "s")
        }
        XCTAssertTrue(try XCTUnwrap(p.report().cumulativeTokenSnapshots).isEmpty)
        XCTAssertEqual(p.report().coverage.unsupportedUsageRecords, 4)
        p.consume(event(5, ["input_tokens": 100, "output_tokens": 20, "cached_input_tokens": 101,
            "reasoning_output_tokens": 21]), host: "codex", session: "s")
        let row = try XCTUnwrap(p.report().cumulativeTokenSnapshots?.first)
        XCTAssertEqual(row.inputTokens, 100); XCTAssertNil(row.cachedInputTokens)
        XCTAssertNil(row.cacheWriteInputTokens); XCTAssertNil(row.reasoningOutputTokens)
    }
    func testLastUsageWithoutTotalsAndMissingTimestampsDoNotInventRequests() throws {
        var p = parser()
        var lastOnly = event(5, counters(100))
        var payload = lastOnly["payload"] as! [String: Any]
        payload["info"] = ["last_token_usage": counters(100)]
        lastOnly["payload"] = payload
        p.consume(lastOnly, host: "codex", session: "s")
        var missingTime = event(5, counters(100)); missingTime.removeValue(forKey: "timestamp")
        p.consume(missingTime, host: "codex", session: "s")
        XCTAssertTrue(try XCTUnwrap(p.report().cumulativeTokenSnapshots).isEmpty)
        XCTAssertTrue(p.report().sessionTokens.isEmpty)
        XCTAssertEqual(p.report().coverage.unsupportedUsageRecords, 2)
    }
    func testExistingRequestCountersAndOldReportsRemainSeparate() throws {
        var p = parser()
        p.consume(event(4, counters(100)), host: "codex", session: "s")
        p.tokens(host: "codex", session: "s", id: "resp_1", object: counters(25), time: start.addingTimeInterval(5))
        var report = p.report()
        XCTAssertEqual(report.sessionTokens.first?.inputTokens, 25)
        XCTAssertEqual(report.cumulativeTokenSnapshots?.first?.inputTokens, 100)
        report.cumulativeTokenSnapshots = nil
        let old = try JSONDecoder().decode(ToolUsageReport.self, from: JSONEncoder().encode(report))
        XCTAssertNil(old.cumulativeTokenSnapshots)
    }
}
