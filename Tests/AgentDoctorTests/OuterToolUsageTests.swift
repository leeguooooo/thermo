import XCTest
@testable import AgentDoctor

final class OuterToolUsageTests: XCTestCase {
    private let fixture = ToolUsageTests()

    private func claude(_ id: String, name: String, output: Any?, error: Bool? = nil,
                        time: Double = 1, parser: inout ToolUsageParser) {
        parser.consume(["type": "assistant", "timestamp": fixture.stamp(time), "message": ["content": [
            ["type": "tool_use", "id": id, "name": name, "input": ["command": "fixture-private-command"]]
        ]]], host: "claude", session: "a")
        if let output {
            var block: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": output]
            if let error { block["is_error"] = error }
            parser.consume(["type": "user", "timestamp": fixture.stamp(time + 1),
                            "message": ["content": [block]]], host: "claude", session: "a")
        }
    }

    func testRowsPartitionOuterAggregateWithoutEnteringMCPOrSkillTotals() throws {
        var parser = fixture.parser(); parser.encoding = .cl100k
        claude("a", name: "Bash", output: "abcd", error: false, parser: &parser)
        claude("b", name: "functions.Bash", output: "abcd", error: true, parser: &parser)
        claude("missing", name: "Read", output: nil, parser: &parser)
        parser.consume(fixture.call("mcp", "mcp__fixture__read", 1), host: "codex", session: "a")
        parser.consume(fixture.output("mcp", "abcd", 2), host: "codex", session: "a")
        let report = parser.report(), aggregate = try XCTUnwrap(report.coverage.unattributedResults)
        let rows = try XCTUnwrap(aggregate.byTool), bash = try XCTUnwrap(rows.first { $0.name == "Bash" })
        XCTAssertEqual(report.tools.count, 1); XCTAssertEqual(report.tools.first?.kind, "mcp")
        XCTAssertEqual(report.returnedTextSummary(kind: "mcp").returnedTextBytes, 4)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.calls }, report.coverage.otherToolCalls)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.completed }, aggregate.completed)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.missingResults }, aggregate.missingResults)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.returnedTextBytes }, aggregate.returnedTextBytes)
        XCTAssertEqual(bash.calls, 2); XCTAssertEqual(bash.completed, 2)
        XCTAssertEqual(bash.reportedErrors, 1); XCTAssertEqual(bash.explicitErrorRate, 0.5)
        XCTAssertEqual(bash.referenceReturnedTextTokens, 2)
        XCTAssertEqual(report.outerReturnedTextSummary?.percentage(of: bash), 100)
        XCTAssertNil(report.returnedTextSummary(kind: "mcp").percentage(of: bash))
        let exported = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(exported.contains("fixture-private-command"))
    }

    func testOutOfOrderInnerErrorNeverBecomesOuterFailure() throws {
        var parser = fixture.parser()
        let value = #"{"isError":true,"content":[{"type":"text","text":"abcd"}]}"#
        parser.consume(fixture.output("a", value, 2), host: "codex", session: "a")
        parser.consume(fixture.call("a", "functions.exec", 1), host: "codex", session: "a")
        parser.consume(fixture.output("a", "duplicate", 3), host: "codex", session: "a")
        parser.consume(fixture.output("orphan", "unmatched", 2), host: "codex", session: "a")
        let report = parser.report(), row = try XCTUnwrap(report.coverage.unattributedResults?.byTool?.first)
        XCTAssertEqual(row.name, "exec"); XCTAssertEqual(row.calls, 1); XCTAssertEqual(row.completed, 1)
        XCTAssertEqual(row.reportedErrors, 0); XCTAssertEqual(row.unknownErrorStatus, 1)
        XCTAssertNil(row.explicitErrorRate); XCTAssertEqual(row.returnedTextBytes, 4)
        XCTAssertEqual(report.coverage.unmatchedResults, 1)
        XCTAssertEqual(report.coverage.duplicateRecords, 1)
        XCTAssertTrue(report.tools.isEmpty)
    }

    func testMediaAndUnknownContentDoNotFabricateReferenceTotals() throws {
        var parser = fixture.parser(); parser.encoding = .cl100k
        let blocks: [[String: Any]] = [
            ["type": "input_text", "text": "abcd"],
            ["type": "input_image", "image_url": "fixture-private-image"],
            ["type": "input_future", "data": "fixture-private-data"]
        ]
        parser.consume(fixture.call("a", "exec", 1), host: "codex", session: "a")
        parser.consume(fixture.output("a", blocks, 2), host: "codex", session: "a")
        let report = parser.report(), aggregate = try XCTUnwrap(report.coverage.unattributedResults)
        let row = try XCTUnwrap(aggregate.byTool?.first)
        XCTAssertEqual(row.returnedTextBytes, 4); XCTAssertEqual(row.nonTextBlocks, 2)
        XCTAssertEqual(row.unmeasuredResults, 1); XCTAssertEqual(row.unavailableReferenceResults, 1)
        XCTAssertNil(row.referenceReturnedTextTokens)
        XCTAssertNil(report.outerReturnedTextSummary?.returnedTextTokens)
        XCTAssertEqual(report.outerReturnedTextSummary?.returnedTextBytes, 4)
        XCTAssertEqual(row.nonTextBlocks, aggregate.nonTextBlocks)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("fixture-private"))
    }

    func testTimingWindowMissingResultsAndP95UseOnlyValidPairs() throws {
        var parser = fixture.parser()
        for n in 1...20 {
            parser.consume(fixture.call(String(n), "exec", 1), host: "codex", session: "a")
            parser.consume(fixture.output(String(n), "", Double(n + 1)), host: "codex", session: "a")
        }
        parser.consume(fixture.call("missing", "exec", 1), host: "codex", session: "a")
        parser.consume(fixture.call("late", "exec", 1), host: "codex", session: "a")
        parser.consume(fixture.output("late", "outside", 101), host: "codex", session: "a")
        parser.consume(fixture.call("old", "exec", -1), host: "codex", session: "a")
        parser.consume(fixture.output("old", "outside", 2), host: "codex", session: "a")
        let row = try XCTUnwrap(parser.report().coverage.unattributedResults?.byTool?.first)
        XCTAssertEqual(row.calls, 22); XCTAssertEqual(row.completed, 20); XCTAssertEqual(row.missingResults, 2)
        XCTAssertEqual(row.timingSamples, 20); XCTAssertEqual(row.medianSeconds, 10.5)
        XCTAssertEqual(row.p95Seconds, 19); XCTAssertEqual(row.totalObservedSeconds, 210)
    }

    func testHostIsolationAndInvalidNamesDoNotExportPaths() throws {
        var parser = fixture.parser()
        claude("a", name: "Bash", output: "fixture-private-output", parser: &parser)
        parser.consume(fixture.call("a", "Bash", 1), host: "codex", session: "a")
        parser.consume(fixture.output("a", "y", 2), host: "codex", session: "a")
        for name in ["fixture-private/path", "fixture-private\nname"] {
            claude(name, name: name, output: "x", parser: &parser)
        }
        let report = parser.report(), rows = try XCTUnwrap(report.coverage.unattributedResults?.byTool)
        XCTAssertEqual(rows.filter { $0.name == "Bash" }.count, 2)
        XCTAssertEqual(rows.first { $0.name == "Unidentified outer tool" }?.calls, 2)
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("fixture-private"))
    }

    func testLegacyAggregateWithoutRowsRemainsUnmeasured() throws {
        var parser = fixture.parser()
        claude("a", name: "Read", output: "x", parser: &parser)
        let encoded = try JSONEncoder().encode(parser.report())
        let fresh = try JSONDecoder().decode(ToolUsageReport.self, from: encoded)
        XCTAssertEqual(fresh.coverage.unattributedResults?.byTool?.count, 1)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var coverage = try XCTUnwrap(object["coverage"] as? [String: Any])
        var aggregate = try XCTUnwrap(coverage["unattributedResults"] as? [String: Any])
        aggregate.removeValue(forKey: "byTool"); coverage["unattributedResults"] = aggregate
        object["coverage"] = coverage
        let old = try JSONDecoder().decode(ToolUsageReport.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.coverage.unattributedResults?.completed, 1)
        XCTAssertNil(old.coverage.unattributedResults?.byTool)
        XCTAssertNil(old.outerReturnedTextSummary)
    }
}
