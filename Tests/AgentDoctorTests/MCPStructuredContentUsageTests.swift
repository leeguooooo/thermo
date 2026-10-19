import XCTest
@testable import AgentDoctor

final class MCPStructuredContentUsageTests: XCTestCase {
    func parser(_ encoding: TextEncoding = .heuristic) -> ToolUsageParser {
        var p = ToolUsageParser(since: Date(timeIntervalSince1970: 0), until: Date(timeIntervalSince1970: 100))
        p.encoding = encoding; return p
    }
    func add(_ value: Any?, to p: inout ToolUsageParser, id: String = "one", name: String = "mcp__owned__tool", endFirst: Bool = false, failed: Bool = false) {
        if !endFirst { p.start(host: "codex", session: "s", id: id, name: name, input: nil, time: Date(timeIntervalSince1970: 1)) }
        p.end(host: "codex", session: "s", id: id, value: value, error: nil, time: Date(timeIntervalSince1970: 2), invocationFailed: failed)
        if endFirst { p.start(host: "codex", session: "s", id: id, name: name, input: nil, time: Date(timeIntervalSince1970: 1)) }
    }
    func testAcknowledgmentDoesNotHideStructuredRepresentationOrChangeTextAccounting() throws {
        var p = parser()
        add(["content": [["type":"text", "text":"OK"]], "structuredContent":["value":"PRIVATE_DETAIL"]], to: &p)
        let row = try XCTUnwrap(p.report().tools.first), usage = try XCTUnwrap(row.structuredContent)
        XCTAssertEqual(row.returnedTextBytes, 2)
        XCTAssertEqual(usage.jsonBytes, #"{"value":"PRIVATE_DETAIL"}"#.utf8.count)
        XCTAssertEqual(usage.inspectedResultObjects, 1); XCTAssertEqual(usage.structuredResults, 1)
        XCTAssertEqual(usage.alongsideContentResults, 1); XCTAssertEqual(usage.unobservableResults, 0)
        XCTAssertEqual(row.unknownErrorStatus, 1); XCTAssertNil(usage.jsonReferenceTokens)
        let encoded = String(decoding: try JSONEncoder().encode(p.report()), as: UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE_DETAIL"))
    }
    func testEnvelopeAbsenceDiffersFromUnobservableTextAndNestedPayloadIsNotInspected() throws {
        var p = parser()
        add(["content": [["type":"text", "text":"OK"]]], to: &p, id: "absent")
        add([["type":"text", "text":#"{"structuredContent":{"private":"hidden"}}"#]], to: &p, id: "nested")
        add("ordinary text", to: &p, id: "plain")
        let row = try XCTUnwrap(p.report().tools.first), usage = try XCTUnwrap(row.structuredContent)
        XCTAssertEqual(row.completed, 3); XCTAssertEqual(usage.inspectedResultObjects, 1)
        XCTAssertEqual(usage.unobservableResults, 2); XCTAssertEqual(usage.structuredResults, 0)
        XCTAssertTrue(row.mcpStructuredContentLines.count > 1)
    }
    func testJSONEncodedEnvelopeAndEndFirstAreMeasuredOnce() throws {
        var p = parser()
        let value = #"{"content":[],"structuredContent":{"n":1}}"#
        add(value, to: &p, endFirst: true)
        p.end(host: "codex", session: "s", id: "one", value: value, error: nil, time: Date(timeIntervalSince1970: 3))
        let usage = try XCTUnwrap(p.report().tools.first?.structuredContent)
        XCTAssertEqual(usage.jsonBytes, 7); XCTAssertEqual(usage.structuredResults, 1)
        XCTAssertEqual(p.report().coverage.duplicateRecords, 1)
    }
    func testStructuredOnlyReferenceTokensStaySeparateFromLegacyTextFallback() throws {
        var p = parser(.cl100k)
        add(["structuredContent":["n":1]], to: &p)
        let row = try XCTUnwrap(p.report().tools.first), usage = try XCTUnwrap(row.structuredContent)
        XCTAssertEqual(usage.jsonBytes, 7); XCTAssertEqual(usage.alongsideContentResults, 0)
        XCTAssertEqual(usage.jsonReferenceTokens, 5)
        XCTAssertEqual(row.referenceReturnedTextTokens, usage.jsonReferenceTokens)
        XCTAssertEqual(p.report().returnedTextSummary(kind: "mcp").returnedTextBytes, 7)
    }
    func testMalformedStructuredFieldsAreNotZeroSizedSuccesses() throws {
        var p = parser(.cl100k)
        for (i, value) in ([NSNull(), "bad", [1, 2]] as [Any]).enumerated() {
            add(["content": [], "structuredContent":value], to: &p, id: String(i))
        }
        let usage = try XCTUnwrap(p.report().tools.first?.structuredContent)
        XCTAssertEqual(usage.structuredResults, 3); XCTAssertEqual(usage.unavailableJSONResults, 3)
        XCTAssertEqual(usage.jsonBytes, 0); XCTAssertNil(usage.jsonReferenceTokens)
    }
    func testMissingAndInvocationFailureDoNotAcquireResultCoverage() throws {
        var p = parser()
        add(nil, to: &p, id: "failed", failed: true)
        p.start(host: "codex", session: "s", id: "missing", name: "mcp__owned__tool", input: nil, time: Date(timeIntervalSince1970: 1))
        let row = try XCTUnwrap(p.report().tools.first), usage = try XCTUnwrap(row.structuredContent)
        XCTAssertEqual(row.invocationFailures, 1); XCTAssertEqual(row.missingResults, 1)
        XCTAssertEqual(row.completed, 0); XCTAssertEqual(usage.inspectedResultObjects, 0)
        XCTAssertEqual(usage.unobservableResults, 0)
    }
    func testOuterAndSkillResultsNeverAcquireMCPStructuredCounters() throws {
        for name in ["functions.exec", "Skill"] {
            var p = parser()
            p.start(host: "claude", session: "s", id: "one", name: name, input: ["skill":"owned"], time: Date(timeIntervalSince1970: 1))
            p.end(host: "claude", session: "s", id: "one", value: ["structuredContent":["n":1]], error: nil, time: Date(timeIntervalSince1970: 2))
            XCTAssertTrue(p.report().tools.allSatisfy { $0.structuredContent == nil })
            XCTAssertTrue((p.report().coverage.unattributedResults?.byTool ?? []).allSatisfy { $0.structuredContent == nil })
        }
    }
    func testOldReportKeepsCoverageUnknown() throws {
        let row = ToolUsageRow(id: "one", host: "codex", kind: "mcp", name: "tool")
        let old = try JSONDecoder().decode(ToolUsageRow.self, from: JSONEncoder().encode(row))
        XCTAssertNil(old.structuredContent); XCTAssertEqual(old.mcpStructuredContentLines.count, 1)
    }
}
