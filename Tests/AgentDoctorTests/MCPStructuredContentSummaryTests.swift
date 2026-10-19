import XCTest
@testable import AgentDoctor

final class MCPStructuredContentSummaryTests: XCTestCase {
    func row(_ id: String, value: Any? = ["n": 1], encoding: TextEncoding = .heuristic) -> ToolUsageRow {
        var row = ToolUsageRow(id: id, host: "codex", kind: "mcp", name: id)
        row.calls = 1; row.completed = 1; row.invocationFailures = 0
        row.referenceEncoding = encoding == .heuristic ? nil : encoding.rawValue
        var usage = MCPStructuredContentUsage(encoding: encoding)
        usage.record(MCPStructuredResultObservation(value.map { ["structuredContent": $0] } ?? [:], encoding: encoding))
        row.structuredContent = usage; return row
    }
    func testCompleteSummaryIncludesEveryMCPRowButNeverOtherCategories() {
        let a = row("a"), b = row("b", value: NSNull())
        var outer = a; outer.id = "outer"; outer.kind = "outer"
        let s = MCPStructuredContentSummary(rows: [a,b,outer], encoding: nil, logComplete: true)
        XCTAssertEqual(s.completedResults, 2); XCTAssertEqual(s.checkedEnvelopes, 2)
        XCTAssertEqual(s.totalJSONBytes, 11); XCTAssertEqual(s.totalJSONTokens, 3)
        XCTAssertEqual(s.structuredResults, 2)
    }
    func testAbsentFieldIsKnownZeroButNoCompletedResultsIsUnknown() {
        let s = MCPStructuredContentSummary(rows: [row("absent", value: nil)], encoding: nil, logComplete: true)
        XCTAssertEqual(s.totalJSONBytes, 0); XCTAssertEqual(s.totalJSONTokens, 0)
        let empty = MCPStructuredContentSummary(rows: [], encoding: nil, logComplete: true)
        XCTAssertNil(empty.totalJSONBytes); XCTAssertNil(empty.totalJSONTokens)
    }
    func testSummaryDoesNotStopAtTheVisibleRowLimit() {
        let rows = (0..<64).map { row("tool-\($0)") }
        let summary = MCPStructuredContentSummary(rows: rows, encoding: nil, logComplete: true)
        XCTAssertEqual(summary.completedResults, 64)
        XCTAssertEqual(summary.totalJSONBytes, 448)
        XCTAssertEqual(summary.totalJSONTokens, 128)
    }
    func testPartialLogsRetainMeasuredSubsetWithoutPromotingItToTotal() {
        let s = MCPStructuredContentSummary(rows: [row("one")], encoding: nil, logComplete: false)
        XCTAssertEqual(s.knownJSONBytes, 7); XCTAssertEqual(s.knownJSONTokens, 2)
        XCTAssertNil(s.totalJSONBytes); XCTAssertNil(s.totalJSONTokens)
    }
    func testMissingAndFailedRepliesMakeTotalsUnknown() {
        for failed in [false,true] {
            var missing = row("missing"); missing.completed = 0
            missing.structuredContent = MCPStructuredContentUsage(encoding: .heuristic)
            missing.missingResults = failed ? 0 : 1; missing.invocationFailures = failed ? 1 : 0
            let s = MCPStructuredContentSummary(rows: [row("known"),missing], encoding: nil, logComplete: true)
            XCTAssertEqual(s.knownJSONBytes, 7); XCTAssertNil(s.totalJSONBytes); XCTAssertNil(s.totalJSONTokens)
        }
    }
    func testUnobservableAndUnmeasurableResultsDoNotBecomeZero() {
        for unreadable in [false,true] {
            var r = row("partial");r.calls = 2;r.completed = 2
            r.structuredContent?.record(unreadable ? .unobservable : .present(nil, alongsideContent: false))
            let s = MCPStructuredContentSummary(rows: [r], encoding: nil, logComplete: true)
            XCTAssertEqual(s.knownJSONBytes, 7); XCTAssertNil(s.totalJSONBytes)
            XCTAssertEqual(s.unobservableResults, unreadable ? 1 : 0)
            XCTAssertEqual(s.unmeasurableFields, unreadable ? 0 : 1)
        }
    }
    func testUnavailableReferenceDoesNotEraseKnownBytesOrFallBackToHeuristic() {
        var r = row("one", encoding: .cl100k);r.structuredContent?.jsonReferenceTokens = nil
        let s = MCPStructuredContentSummary(rows: [r], encoding: "cl100k_base", logComplete: true)
        XCTAssertEqual(s.totalJSONBytes, 7); XCTAssertNil(s.totalJSONTokens)
    }
    func testUnknownOldCoverageMismatchedEncodingsAndDuplicateRowsAreNotTotals() {
        var old = row("old");old.structuredContent = nil
        XCTAssertEqual(MCPStructuredContentSummary(rows: [old], encoding: nil, logComplete: true).uncheckedRows, 1)
        var mismatch = row("wrong");mismatch.referenceEncoding = "cl100k_base"
        for rows in [[mismatch],[row("same"),row("same")]] {
            let s = MCPStructuredContentSummary(rows: rows, encoding: nil, logComplete: true)
            XCTAssertGreaterThan(s.inconsistentRows, 0);XCTAssertNil(s.totalJSONBytes)
        }
        var bad = row("bad");bad.structuredContent?.inspectedResultObjects = 2
        XCTAssertNil(MCPStructuredContentSummary(rows: [bad], encoding: nil, logComplete: true).totalJSONBytes)
    }
    func testOverflowIsUnknownAndNeverWrappedIntoAZero() {
        var a = row("a"), b = row("b")
        a.structuredContent?.jsonBytes = Int.max;b.structuredContent?.jsonBytes = Int.max
        let s = MCPStructuredContentSummary(rows: [a,b], encoding: nil, logComplete: true)
        XCTAssertNil(s.knownJSONBytes);XCTAssertNil(s.totalJSONBytes)
    }
    func testStoredSummaryRoundTripsAndCannotOutliveItsSourceRows() throws {
        var p = ToolUsageParser(since: Date(timeIntervalSince1970: 0), until: Date(timeIntervalSince1970: 10))
        p.start(host: "codex", session: "s", id: "one", name: "mcp__owned__tool", input: nil, time: Date(timeIntervalSince1970: 1))
        p.end(host: "codex", session: "s", id: "one", value: ["content":[], "structuredContent": NSNull()], error: false, time: Date(timeIntervalSince1970: 2))
        let report = p.report();XCTAssertEqual(report.observedMCPStructuredSummary?.totalJSONBytes, 4)
        var decoded = try JSONDecoder().decode(ToolUsageReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded.observedMCPStructuredSummary, report.observedMCPStructuredSummary)
        decoded.tools[0].completed += 1
        XCTAssertNil(decoded.observedMCPStructuredSummary)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        object.removeValue(forKey: "mcpStructuredSummary")
        let old = try JSONDecoder().decode(ToolUsageReport.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.observedMCPStructuredSummary)
    }
}
