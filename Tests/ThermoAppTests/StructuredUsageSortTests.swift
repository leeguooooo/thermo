import XCTest
@testable import AgentDoctor
@testable import ThermoApp

final class StructuredUsageSortTests: XCTestCase {
    func row(_ id: String, text: Int, json: Int, reference: Int? = nil) throws -> ToolUsageRow {
        var value = ToolUsageRow(id: id, host: "codex", kind: "mcp", name: id)
        value.calls = 1; value.completed = 1; value.returnedTextEstimatedTokens = text
        value.referenceEncoding = reference == nil ? nil : "cl100k_base"
        // Decode the structured counters as public report data.
        let data = try JSONSerialization.data(withJSONObject: ["inspectedResultObjects":1,"unobservableResults":0,
            "structuredResults":1,"alongsideContentResults":1,"jsonBytes":json * 4,
            "jsonEstimatedTokens":json,"jsonReferenceTokens":reference ?? json,"unavailableJSONResults":0])
        value.structuredContent = try JSONDecoder().decode(MCPStructuredContentUsage.self, from: data)
        return value
    }
    func testLargeJSONWithShortAcknowledgmentRanksBeforeLongTextWithSmallJSON() throws {
        let short = try row("short", text: 1000, json: 2)
        let wide = try row("wide", text: 4, json: 3000)
        let order = [short, wide].sorted { ToolUsagePanel.UsageSort.structured.value($0) > ToolUsagePanel.UsageSort.structured.value($1) }
        XCTAssertEqual(order.map(\.id), ["wide", "short"])
        XCTAssertGreaterThan(ToolUsagePanel.UsageSort.text.value(short), ToolUsagePanel.UsageSort.text.value(wide))
    }
    func testReferenceEncodingControlsRankingRatherThanHeuristicEstimate() throws {
        let a = try row("a", text: 1, json: 500, reference: 2)
        let b = try row("b", text: 1, json: 4, reference: 100)
        XCTAssertLessThan(ToolUsagePanel.UsageSort.structured.value(a), ToolUsagePanel.UsageSort.structured.value(b))
    }
    func testUnknownCoverageAndLegacyReportsStayAfterVerifiedZero() throws {
        var zero = try row("zero", text: 1, json: 0)
        zero.structuredContent?.structuredResults = 0; zero.structuredContent?.alongsideContentResults = 0
        var unknown = try row("unknown", text: 1, json: 1000)
        unknown.structuredContent?.unobservableResults = 1
        var legacy = unknown; legacy.structuredContent = nil
        var invalid = unknown; invalid.structuredContent?.unobservableResults = 0; invalid.structuredContent?.unavailableJSONResults = 1
        var missing = zero; missing.completed = 0
        for value in [unknown, legacy, invalid, missing] {
            XCTAssertNil(value.observedStructuredJSONTokens)
            XCTAssertLessThan(ToolUsagePanel.UsageSort.structured.value(value), ToolUsagePanel.UsageSort.structured.value(zero))
        }
        XCTAssertEqual(zero.observedStructuredJSONTokens, 0)
    }
}
