import XCTest
@testable import AgentDoctor

final class ReferenceEncodingIntegrationTests: XCTestCase {
    var home: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }
    func skill(_ name: String, body: String) throws {
        let folder = home.appendingPathComponent(".agents/skills/" + name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: fixture\n---\n\(body)".write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }
    func testFootprintKeepsHeuristicSeparateFromReferenceAndLiteralControlMarkers() throws {
        let text = "我们能看出来 MCP 占多少 token？ <|endoftext|>"
        let measured = TextFootprint(text, encoding: .o200k)
        XCTAssertEqual(measured.estimatedTokens, TextFootprint(text).estimatedTokens)
        XCTAssertEqual(measured.referenceTokens, try ReferenceTokenizer.o200k.get().tokens(text).count)
        XCTAssertEqual(measured.comparisonTokens, measured.referenceTokens)
        XCTAssertEqual(measured.referenceEncoding, "o200k_base")
        XCTAssertNil(measured.referenceError)
    }
    func testContextTotalsDoNotPresentPartialReferenceCountsAsComplete() throws {
        try skill("a", body: String(repeating: "x", count: 65_537))
        try skill("b", body: "short text")
        try skill("c", body: "another short text")
        let report = AgentDoctor.context(DoctorEnvironment(home: home, tokenEncoding: .o200k))
        let totals = try XCTUnwrap(report.summaries.first)
        XCTAssertEqual(report.referenceEncoding, "o200k_base")
        XCTAssertNotNil(report.referenceEngine)
        XCTAssertEqual(totals.unavailableReferenceFiles, 1)
        XCTAssertNil(totals.referenceDocumentTokens)
        XCTAssertNotNil(totals.referenceCatalogTokens)
        XCTAssertGreaterThan(totals.documentEstimatedTokens, 0)
        XCTAssertEqual(report.skills.last?.name, "a", "unavailable counts sort after measured counts")
    }
    func testMCPDefinitionComponentsUseRequestedEncodingWithoutCallingTools() throws {
        let row = try MCPInspector.footprint(["name": "fixture", "description": "搜索文档", "inputSchema": ["type": "object"]], encoding: .cl100k)
        XCTAssertNotNil(row.definition.referenceTokens)
        XCTAssertNotNil(row.description.referenceTokens)
        XCTAssertEqual(row.description.referenceEncoding, "cl100k_base")
        XCTAssertNil(row.definition.referenceError)
    }
    func testUsageKeepsReferenceOutputCountsSeparateFromNativeRequestCounters() throws {
        let now = Date()
        var parser = ToolUsageParser(since: now.addingTimeInterval(-10), until: now.addingTimeInterval(10), encoding: .cl100k)
        let stamp = ISO8601DateFormatter().string(from: now)
        parser.consume(["timestamp": stamp, "type": "response_item", "payload": ["type": "function_call", "call_id": "a", "name": "mcp__fixture__read"]], host: "codex", session: "a")
        parser.consume(["timestamp": stamp, "type": "response_item", "payload": ["type": "function_call_output", "call_id": "a", "output": "中文说明"]], host: "codex", session: "a")
        let report = parser.report()
        XCTAssertEqual(report.tools.first?.referenceReturnedTextTokens, try ReferenceTokenizer.cl100k.get().tokens("中文说明").count)
        XCTAssertEqual(report.tools.first?.referenceEncoding, "cl100k_base")
        XCTAssertTrue(report.sessionTokens.isEmpty)
        XCTAssertNotNil(report.referenceEngine)
    }
    func testOlderUsageReportDecodesWithoutReferenceFields() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("docs/measurements/observed-tool-usage-fixture-2026-10-17.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(ToolUsageReport.self, from: Data(contentsOf: file))
        XCTAssertNil(report.referenceEncoding)
        XCTAssertNil(report.tools.first?.referenceEncoding)
        XCTAssertNil(report.tools.first?.unavailableReferenceResults)
    }
}
