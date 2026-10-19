import XCTest
@testable import AgentDoctor

final class ToolUsageOrderingTests: XCTestCase {
    func row(_ id: String, bytes: Int = 0, estimate: Int = 0, reference: Int? = nil) -> ToolUsageRow {
        var row = ToolUsageRow(id: id, host: "codex", kind: "mcp", name: id)
        row.completed = 1; row.calls = 1; row.returnedTextBytes = bytes
        row.returnedTextEstimatedTokens = estimate; row.referenceReturnedTextTokens = reference
        row.referenceEncoding = reference == nil ? nil : "cl100k_base"
        return row
    }
    func testTextOrderUsesSelectedTokenCountRatherThanBytes() {
        let largeBytes = row("bytes", bytes: 1000, estimate: 250, reference: 125)
        let moreTokens = row("tokens", bytes: 600, estimate: 200, reference: 200)
        XCTAssertEqual(ToolUsageOrdering.text.sorted([largeBytes,moreTokens]).map(\.id), ["tokens","bytes"])
        var a = largeBytes, b = moreTokens; a.referenceEncoding = nil; b.referenceEncoding = nil
        XCTAssertEqual(ToolUsageOrdering.text.sorted([b,a]).map(\.id), ["bytes","tokens"])
        a.referenceEncoding = "cl100k_base"; a.referenceReturnedTextTokens = nil
        XCTAssertNil(ToolUsageOrdering.text.count(for:a))
        XCTAssertEqual(ToolUsageOrdering.text.sorted([a,b]).first?.id,"tokens")
    }
    func testStructuredOrderKeepsKnownZeroBeforeUnknownAndOtherCategories() {
        var wide = row("wide", estimate: 1), zero = row("zero", estimate: 1)
        var usage = MCPStructuredContentUsage(encoding:.heuristic)
        usage.inspectedResultObjects = 1; usage.structuredResults = 1; usage.jsonBytes = 4000; usage.jsonEstimatedTokens = 1000
        wide.structuredContent = usage
        var absent = MCPStructuredContentUsage(encoding:.heuristic); absent.inspectedResultObjects = 1
        zero.structuredContent = absent
        var unknown = wide; unknown.id = "unknown"; unknown.structuredContent?.unobservableResults = 1
        var skill = wide; skill.id = "skill"; skill.kind = "skill"
        let ordered = ToolUsageOrdering.structured.sorted([unknown,skill,zero,wide])
        XCTAssertEqual(ordered.map(\.id),["wide","zero","skill","unknown"])
        XCTAssertNil(ToolUsageOrdering.structured.count(for:skill)); XCTAssertNil(ToolUsageOrdering.structured.count(for:unknown))
    }
    func testTiesAreStableAndNegativeOrUnavailableCountsNeverBecomeKnownZero() {
        let a = row("a", estimate: 0), b = row("b", estimate: 0)
        var invalid = row("invalid", estimate: -100)
        XCTAssertEqual(ToolUsageOrdering.text.sorted([b,invalid,a]).map(\.id),["a","b","invalid"])
        invalid.referenceEncoding = "cl100k_base"; invalid.referenceReturnedTextTokens = -1
        XCTAssertNil(ToolUsageOrdering.text.count(for:invalid))
        XCTAssertEqual(ToolUsageOrdering.text.sorted([invalid,a,b]).map(\.id),["a","b","invalid"])
    }
    func testOrderingIsOptionalForOlderReportsAndRoundTripsWhenDeclared() throws {
        let parser = ToolUsageParser(since:Date(timeIntervalSince1970:0),until:Date(timeIntervalSince1970:100))
        var report = parser.report()
        XCTAssertNil(try JSONDecoder().decode(ToolUsageReport.self,from:JSONEncoder().encode(report)).toolOrdering)
        report.toolOrdering = .structured
        XCTAssertEqual(try JSONDecoder().decode(ToolUsageReport.self,from:JSONEncoder().encode(report)).toolOrdering,.structured)
    }
}
