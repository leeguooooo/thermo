import XCTest
@testable import AgentDoctor

final class ToolUsageTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    func parser() -> ToolUsageParser { ToolUsageParser(since: start, until: start.addingTimeInterval(100)) }
    func stamp(_ seconds: Double) -> String { ISO8601DateFormatter().string(from: start.addingTimeInterval(seconds)) }
    func event(_ type: String, _ payload: [String: Any], _ seconds: Double) -> [String: Any] {
        ["timestamp": stamp(seconds), "type": type, "payload": payload]
    }
    func call(_ id: String, _ name: String, _ seconds: Double) -> [String: Any] {
        event("response_item", ["type": "function_call", "call_id": id, "name": name, "arguments": "private arguments"], seconds)
    }
    func output(_ id: String, _ value: Any, _ seconds: Double) -> [String: Any] {
        event("response_item", ["type": "function_call_output", "call_id": id, "output": value], seconds)
    }
    func native(_ id: String, server: String = "server", tool: String = "tool", result: Any = ["content": [["type": "text", "text": "fixture-private-result"]]], start seconds: Double = 1) -> [String: Any] {
        ["type": "event_msg", "timestamp": stamp(90), "payload": ["type": "item_completed",
            "started_at_ms": start.addingTimeInterval(seconds).timeIntervalSince1970 * 1000,
            "completed_at_ms": start.addingTimeInterval(seconds + 2).timeIntervalSince1970 * 1000,
            "item": ["type": "McpToolCall", "id": id, "server": server, "tool": tool, "status": "completed",
                     "arguments": ["private": "fixture-private-argument"], "result": result]]]
    }
    func testNativeMCPCompletionRetainsRealFieldsWithoutInferringSuccessFromLifecycle() throws {
        var p = parser()
        p.consume(native("native"), host: "codex", session: "a")
        let report = p.report(), row = try XCTUnwrap(report.tools.first)
        XCTAssertEqual(row.server, "server"); XCTAssertEqual(row.name, "tool")
        XCTAssertEqual(row.calls, 1); XCTAssertEqual(row.completed, 1)
        XCTAssertEqual(row.reportedErrors, 0); XCTAssertEqual(row.unknownErrorStatus, 1)
        XCTAssertNil(row.explicitErrorRate)
        XCTAssertEqual(row.medianSeconds, 2)
        XCTAssertEqual(row.returnedTextBytes, "fixture-private-result".utf8.count)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("fixture-private"))
    }
    func testUnmetAssertionKeepsExplicitMCPErrorDespiteSuccessfulExecutionPayload() throws {
        var p = parser()
        let body = #"{"success":true,"data":{"pass":false,"timedOut":false},"error":null}"#
        p.consume(native("assertion", tool: "expect", result: ["isError": true,
            "content": [["type": "text", "text": body]]]), host: "codex", session: "a")
        let row = try XCTUnwrap(p.report().tools.first)
        XCTAssertEqual(row.reportedErrors, 1)
        XCTAssertEqual(row.unknownErrorStatus, 0)
        XCTAssertEqual(row.explicitErrorRate, 1)
    }
    func testReturnedTextSharesUseAllCategoryRowsAndNeverRequestCounters() throws {
        var p = parser()
        p.consume(native("a", tool: "large", result: ["content": [["type": "text", "text": "abcdefghijkl"]]]), host: "codex", session: "a")
        p.consume(native("b", tool: "small", result: ["content": [["type": "text", "text": "abcd"]]]), host: "codex", session: "a")
        var report = p.report()
        var skill = ToolUsageRow(id: "skill", host: "claude", kind: "skill", name: "skill")
        skill.returnedTextBytes = 400; skill.returnedTextEstimatedTokens = 100
        report.tools.append(skill)
        report.sessionTokens = [LoggedTokenUsage(host: "codex", requests: 1, inputTokens: 999999, outputTokens: 1, semantics: "fixture")]
        let summary = report.returnedTextSummary(kind: "mcp")
        XCTAssertEqual(summary.returnedTextBytes, 16)
        XCTAssertEqual(summary.returnedTextTokens, 4)
        XCTAssertEqual(summary.percentage(of: try XCTUnwrap(report.tools.first { $0.name == "large" })), 75)
        XCTAssertNil(summary.percentage(of: skill))
        XCTAssertEqual(report.returnedTextSummary(kind: "skill").returnedTextTokens, 100)
    }
    func testReferenceSharesStayUnknownWhenAnyCountOrEncodingIsUnavailable() throws {
        var report = parser().report()
        report.referenceEncoding = "cl100k_base"
        var row = ToolUsageRow(id: "a", host: "codex", kind: "mcp", name: "tool")
        row.completed = 1; row.returnedTextBytes = 4; row.referenceEncoding = "cl100k_base"
        row.referenceReturnedTextTokens = 3
        report.tools = [row]
        XCTAssertEqual(report.returnedTextSummary(kind: "mcp").percentage(of: row), 100)
        var unavailable = row; unavailable.id = "b"; unavailable.referenceReturnedTextTokens = nil
        report.tools.append(unavailable)
        XCTAssertNil(report.returnedTextSummary(kind: "mcp").returnedTextTokens)
        XCTAssertNil(report.returnedTextSummary(kind: "mcp").percentage(of: row))
        report.tools[1].referenceReturnedTextTokens = 3
        report.tools[1].unavailableReferenceResults = 1
        XCTAssertNil(report.returnedTextSummary(kind: "mcp").returnedTextTokens)
        report.tools[1].unavailableReferenceResults = 0
        report.tools[1].referenceEncoding = "o200k_base"
        XCTAssertNil(report.returnedTextSummary(kind: "mcp").returnedTextTokens)
    }
    func testEmptyZeroOverflowAndMissingResultsDoNotCreateFalseShares() {
        var report = parser().report()
        XCTAssertEqual(report.returnedTextSummary(kind: "mcp").returnedTextTokens, 0)
        var row = ToolUsageRow(id: "a", host: "codex", kind: "mcp", name: "tool")
        report.tools = [row]
        XCTAssertNil(report.returnedTextSummary(kind: "mcp").percentage(of: row))
        row.returnedTextEstimatedTokens = Int.max; row.returnedTextBytes = Int.max
        var other = row; other.id = "b"
        report.tools = [row, other]
        XCTAssertNil(report.returnedTextSummary(kind: "mcp").returnedTextTokens)
        XCTAssertNil(report.returnedTextSummary(kind: "mcp").returnedTextBytes)
        row.returnedTextEstimatedTokens = -1
        report.tools = [row]
        XCTAssertNil(report.returnedTextSummary(kind: "mcp").returnedTextTokens)
        row.returnedTextBytes = 0; row.referenceEncoding = "cl100k_base"; row.missingResults = 1
        report.referenceEncoding = "cl100k_base"; report.tools = [row]
        XCTAssertEqual(report.returnedTextSummary(kind: "mcp").returnedTextTokens, 0)
        XCTAssertNil(report.returnedTextSummary(kind: "mcp").percentage(of: row))
    }
    func testNativeAndLegacyRecordsDeduplicateInEitherOrderAndGroupOtherCallsTogether() throws {
        let result: [String: Any] = ["isError": false, "content": [["type": "text", "text": "same"]]]
        for nativeFirst in [true, false] {
            var p = parser()
            let legacy = [call("same", "mcp__server__tool", 1), output("same", result, 3)]
            let events = nativeFirst ? [native("same", result: result)] + legacy : legacy + [native("same", result: result)]
            for value in events { p.consume(value, host: "codex", session: "a") }
            p.consume(native("other", result: result), host: "codex", session: "a")
            let report = p.report(), row = try XCTUnwrap(report.tools.first)
            XCTAssertEqual(report.tools.count, 1); XCTAssertEqual(row.calls, 2)
            XCTAssertEqual(row.completed, 2); XCTAssertEqual(row.returnedTextBytes, 8)
            XCTAssertEqual(report.coverage.duplicateRecords, 2)
        }
    }
    func testExplicitNativeServerAndToolFieldsCannotCollideThroughNameDelimiters() {
        var p = parser()
        p.consume(native("a", server: "server__part", tool: "tool"), host: "codex", session: "a")
        p.consume(native("b", server: "server", tool: "part__tool"), host: "codex", session: "a")
        XCTAssertEqual(p.report().tools.count, 2)
        XCTAssertEqual(Set(p.report().tools.compactMap(\.server)), ["server__part", "server"])
    }
    func testNativeMissingResultStaysMissingAndOnlyBooleanFlagsEstablishErrorStatus() throws {
        var p = parser()
        p.consume(native("missing", result: NSNull()), host: "codex", session: "a")
        for (index, flag) in [true as Any, false as Any, "false" as Any, 0 as Any].enumerated() {
            p.consume(native(String(index), result: ["isError": flag, "content": []]), host: "codex", session: "a")
        }
        let row = try XCTUnwrap(p.report().tools.first)
        XCTAssertEqual(row.calls, 5); XCTAssertEqual(row.completed, 4); XCTAssertEqual(row.missingResults, 1)
        XCTAssertEqual(row.reportedErrors, 1); XCTAssertEqual(row.unknownErrorStatus, 2)
        XCTAssertEqual(row.explicitErrorRate, 0.5)
    }
    func testNativeTimingUsesExplicitMillisecondsAndDoesNotFallBackToOuterTimestamp() {
        var p = parser()
        p.consume(native("outside", start: -10), host: "codex", session: "a")
        XCTAssertTrue(p.report().tools.isEmpty)
        var malformed = native("malformed")
        var payload = malformed["payload"] as! [String: Any]; payload["started_at_ms"] = true; malformed["payload"] = payload
        p.consume(malformed, host: "codex", session: "a")
        XCTAssertTrue(p.report().tools.isEmpty)
        XCTAssertEqual(p.report().coverage.missingTimestamps, 1)
        XCTAssertFalse(p.report().complete)
    }
    func testOnlyOneDocumentedFunctionsNamespacePrefixIsRemoved() {
        var p = parser()
        p.consume(call("valid", "functions.mcp__server__tool", 1), host: "codex", session: "a")
        p.consume(call("other", "functions.functions.mcp__server__tool", 1), host: "codex", session: "a")
        XCTAssertEqual(p.report().tools.first?.calls, 1)
        XCTAssertEqual(p.report().coverage.otherToolCalls, 1)
    }
    func testRepeatedReportsDoNotAccumulateDerivedCoverageCounts() {
        var p = parser()
        p.consume(call("other", "exec", 1), host: "codex", session: "a")
        p.consume(output("unmatched", "not attributable", 2), host: "codex", session: "a")
        for _ in 0..<3 {
            let report = p.report()
            XCTAssertEqual(report.coverage.otherToolCalls, 1)
            XCTAssertEqual(report.coverage.unmatchedResults, 1)
            XCTAssertFalse(report.complete)
        }
    }
    func testExplicitErrorProportionUsesOnlyKnownStatusResults() throws {
        var p = parser()
        for id in ["error", "success", "unknown", "missing"] {
            p.consume(call(id, "mcp__server__tool", 1), host: "codex", session: "a")
        }
        p.consume(output("error", ["isError": true, "content": []], 2), host: "codex", session: "a")
        p.consume(output("success", ["isError": false, "content": []], 2), host: "codex", session: "a")
        p.consume(output("unknown", "no explicit status", 2), host: "codex", session: "a")
        let row = try XCTUnwrap(p.report().tools.first)
        XCTAssertEqual(row.calls, 4)
        XCTAssertEqual(row.completed, 3)
        XCTAssertEqual(row.unknownErrorStatus, 1)
        XCTAssertEqual(row.missingResults, 1)
        XCTAssertEqual(row.knownStatusResults, 2)
        XCTAssertEqual(row.explicitErrorRate, 0.5)
    }
    func testNoKnownStatusesIsUnknownRatherThanZeroErrors() {
        var row = ToolUsageRow(id: "fixture", host: "codex", kind: "mcp", name: "tool")
        XCTAssertEqual(row.knownStatusResults, 0)
        XCTAssertNil(row.explicitErrorRate)
        row.calls = 10; row.completed = 7; row.unknownErrorStatus = 7; row.missingResults = 3
        XCTAssertEqual(row.knownStatusResults, 0)
        XCTAssertNil(row.explicitErrorRate)
        row.unknownErrorStatus = 0
        XCTAssertEqual(row.explicitErrorRate, 0)
    }
    func testInconsistentCountersDoNotProduceAnErrorProportion() {
        for (completed, unknown, errors) in [(2, 3, 0), (2, 1, 2), (-1, 0, 0), (2, -1, 0), (2, 0, -1)] {
            var row = ToolUsageRow(id: "fixture", host: "codex", kind: "mcp", name: "tool")
            row.completed = completed; row.unknownErrorStatus = unknown; row.reportedErrors = errors
            XCTAssertNil(row.knownStatusResults)
            XCTAssertNil(row.explicitErrorRate)
        }
    }
    func testConcurrentCallsUseIndependentPairsAndNeverReceiveRequestTokens() throws {
        var p = parser()
        for value in [call("a", "mcp__server__one", 1), call("b", "mcp__server__two", 2), output("b", "longer output", 3), output("a", "ok", 5)] {
            p.consume(value, host: "codex", session: "session")
        }
        let usage = event("token_usage_record", ["response_id": "response", "usage": ["input_tokens": 1000, "cached_input_tokens": 900, "output_tokens": 50]], 6)
        p.consume(usage, host: "codex", session: "session")
        p.consume(usage, host: "codex", session: "session")
        let report = p.report()
        XCTAssertEqual(report.tools.count, 2)
        XCTAssertEqual(report.tools.first { $0.name == "one" }?.totalObservedSeconds, 4)
        XCTAssertEqual(report.tools.first { $0.name == "two" }?.totalObservedSeconds, 1)
        XCTAssertEqual(report.sessionTokens.first?.inputTokens, 1000)
        XCTAssertEqual(report.sessionTokens.first?.requests, 1)
        XCTAssertNil(report.sessionTokens.first?.cacheWriteInputTokens)
        XCTAssertEqual(report.tools.reduce(0) { $0 + $1.returnedTextBytes }, 15)
        XCTAssertTrue(report.tools.allSatisfy { $0.p95Seconds == nil })
    }
    func testDuplicatesAreScopedToSessionAndHost() {
        var p = parser()
        let value = call("same", "mcp__server__tool", 1)
        p.consume(value, host: "codex", session: "a")
        p.consume(value, host: "codex", session: "a")
        p.consume(value, host: "codex", session: "b")
        let report = p.report()
        XCTAssertEqual(report.tools.first?.calls, 2)
        XCTAssertEqual(report.tools.first?.missingResults, 2)
        XCTAssertEqual(report.coverage.duplicateRecords, 1)
    }
    func testImagesAndPrivateTextAreNotExportedAndErrorProseIsNotAFlag() throws {
        var p = parser()
        p.consume(call("a", "mcp__server__tool", 1), host: "codex", session: "a")
        let envelope: [String: Any] = ["content": [["type": "text", "text": "fixture-private-secret ERROR"], ["type": "image", "data": "fixture-base64-secret"]], "isError": false]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        p.consume(output("a", json, 2), host: "codex", session: "a")
        let report = p.report()
        XCTAssertEqual(report.tools.first?.reportedErrors, 0)
        XCTAssertEqual(report.tools.first?.unknownErrorStatus, 0)
        XCTAssertEqual(report.tools.first?.nonTextBlocks, 1)
        XCTAssertEqual(report.tools.first?.returnedTextBytes, "fixture-private-secret ERROR".utf8.count)
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(encoded.contains("fixture-private-secret"))
        XCTAssertFalse(encoded.contains("fixture-base64-secret"))
        XCTAssertFalse(encoded.contains("private arguments"))
    }
    func testUnknownOutcomeAndOutOfOrderTimestampsDoNotInventSuccessOrLatency() {
        var p = parser()
        p.consume(output("a", "ERROR: something", 1), host: "codex", session: "a")
        p.consume(call("a", "mcp__server__tool", 2), host: "codex", session: "a")
        let report = p.report()
        XCTAssertEqual(report.tools.first?.completed, 1)
        XCTAssertEqual(report.tools.first?.unknownErrorStatus, 1)
        XCTAssertEqual(report.tools.first?.timingSamples, 0)
        XCTAssertNil(report.tools.first?.medianSeconds)
        XCTAssertNil(report.tools.first?.totalObservedSeconds)
    }
    func testWindowFilteringAndWrappedCallsRemainExplicitlyUnattributed() {
        var p = parser()
        p.consume(call("old", "mcp__server__tool", -1), host: "codex", session: "a")
        p.consume(call("wrapped", "exec", 1), host: "codex", session: "a")
        p.consume(output("orphan", "text", 2), host: "codex", session: "a")
        let report = p.report()
        XCTAssertTrue(report.tools.isEmpty)
        XCTAssertEqual(report.coverage.otherToolCalls, 1)
        XCTAssertEqual(report.coverage.unmatchedResults, 1)
        XCTAssertFalse(report.complete)
    }
    func testClaudeSkillInvocationAndProgressiveUsageAreCountedOnce() {
        var p = parser()
        for seconds in [1.0, 2.0] {
            let value: [String: Any] = ["timestamp": stamp(seconds), "type": "assistant", "message": ["id": "message", "content": [["type": "tool_use", "id": "tool", "name": "Skill", "input": ["skill": "plugin:fixture", "args": "private prompt"]]], "usage": ["input_tokens": 100, "output_tokens": Int(seconds * 10)]]]
            p.consume(value, host: "claude", session: "a")
        }
        let result: [String: Any] = ["timestamp": stamp(3), "type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "tool", "content": "loaded", "is_error": true]]]]
        p.consume(result, host: "claude", session: "a")
        let report = p.report()
        XCTAssertEqual(report.tools.first?.kind, "skill")
        XCTAssertEqual(report.tools.first?.calls, 1)
        XCTAssertEqual(report.tools.first?.reportedErrors, 1)
        XCTAssertEqual(report.sessionTokens.first?.outputTokens, 20)
        XCTAssertEqual(report.sessionTokens.first?.requests, 1)
    }
    func testP95RequiresTwentySamplesAndUsesNearestRank() {
        var p = parser()
        for index in 1...20 {
            p.consume(call(String(index), "mcp__server__tool", 0), host: "codex", session: "a")
            p.consume(output(String(index), "x", Double(index)), host: "codex", session: "a")
        }
        let row = p.report().tools.first
        XCTAssertEqual(row?.p95Seconds, 19)
        XCTAssertEqual(row?.medianSeconds, 10.5)
        XCTAssertEqual(row?.timingSamples, 20)
    }
    func testReaderClippingMalformedAndPartialLinesAreNotComplete() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent(".codex/sessions/2023/11/14")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var text = String(repeating: " ", count: 4_300_000) + "\ninvalid json\n"
        for object in [call("a", "mcp__server__tool", 1), output("a", "ok", 2)] {
            text += String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
        }
        text += "{unfinished"
        try text.write(to: folder.appendingPathComponent("fixture.jsonl"), atomically: true, encoding: .utf8)
        let report = AgentDoctor.usage(since: start, env: DoctorEnvironment(home: home, now: start.addingTimeInterval(100)))
        XCTAssertFalse(report.complete)
        XCTAssertEqual(report.coverage.filesRead, 1)
        XCTAssertEqual(report.coverage.clippedFiles, 1)
        XCTAssertEqual(report.coverage.malformedLines, 1)
        XCTAssertEqual(report.tools.first?.calls, 1)
        XCTAssertEqual(report.tools.first?.completed, 1)
    }
    func testNativeRequestIDsDeduplicateMirroredLogsAndMissingCacheCountersRemainUnknown() {
        var p = parser()
        let value = event("token_usage_record", ["response_id": "resp_native", "usage": ["input_tokens": 100, "output_tokens": 5]], 1)
        p.consume(value, host: "codex", session: "parent")
        p.consume(value, host: "codex", session: "mirrored")
        let report = p.report()
        XCTAssertEqual(report.sessionTokens.first?.requests, 1)
        XCTAssertEqual(report.sessionTokens.first?.inputTokens, 100)
        XCTAssertNil(report.sessionTokens.first?.cachedInputTokens)
    }
    func testNumericErrorFlagsDoNotBecomeExplicitErrors() {
        var p = parser()
        p.consume(call("a", "mcp__server__tool", 1), host: "codex", session: "a")
        p.consume(output("a", ["content": [["type": "text", "text": "x"]], "isError": 1], 2), host: "codex", session: "a")
        let row = p.report().tools.first
        XCTAssertEqual(row?.reportedErrors, 0)
        XCTAssertEqual(row?.unknownErrorStatus, 1)
    }
    func testReaderLimitsAndCancellationAreExplicit() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let value = String(decoding: try JSONSerialization.data(withJSONObject: call("a", "mcp__server__tool", 1)), as: UTF8.self) + "\n"
        try value.write(to: folder.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        try value.write(to: folder.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
        let report = AgentDoctor.usage(since: start, fileLimit: 1, env: DoctorEnvironment(home: home, now: start.addingTimeInterval(100)))
        XCTAssertEqual(report.coverage.filesRead, 1)
        XCTAssertTrue(report.coverage.limitReached)
        XCTAssertFalse(report.complete)
        let stopped = AgentDoctor.usage(env: DoctorEnvironment(home: home, cancelled: { true }))
        XCTAssertTrue(stopped.coverage.cancelled)
        XCTAssertEqual(stopped.coverage.filesRead, 0)
        XCTAssertFalse(stopped.complete)
    }
    func testRedactedNamesDoNotMergeDifferentTools() throws {
        var p = parser()
        p.consume(call("a", "mcp__server__sk-abcdefghijklmnopqrst", 1), host: "codex", session: "a")
        p.consume(call("b", "mcp__server__sk-abcdefghijklmnopqrstu", 2), host: "codex", session: "a")
        let report = p.report()
        XCTAssertEqual(report.tools.count, 2)
        XCTAssertNotEqual(report.tools[0].id, report.tools[1].id)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(json.contains("abcdefghijklmnop"))
    }
    func testOuterTransportSuccessDoesNotEraseAnExplicitMCPError() throws {
        var p = parser()
        let request: [String: Any] = ["type": "assistant", "timestamp": stamp(1), "message": ["content": [
            ["type": "tool_use", "id": "a", "name": "mcp__server__tool", "input": [:]]
        ]]]
        let envelope = String(decoding: try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "failure"]], "isError": true]), as: UTF8.self)
        let response: [String: Any] = ["type": "user", "timestamp": stamp(2), "message": ["content": [
            ["type": "tool_result", "tool_use_id": "a", "content": envelope, "is_error": false]
        ]]]
        p.consume(request, host: "claude", session: "a")
        p.consume(response, host: "claude", session: "a")
        XCTAssertEqual(p.report().tools.first?.reportedErrors, 1)
    }
    func testUnexpectedSkillArgumentTextIsNotExportedAsAnIdentifier() throws {
        var p = parser()
        p.consume(["type": "assistant", "timestamp": stamp(1), "message": ["content": [
            ["type": "tool_use", "id": "a", "name": "Skill", "input": ["skill": "fixture private account details"]]
        ]]], host: "claude", session: "a")
        let report = p.report()
        XCTAssertTrue(report.tools.isEmpty)
        XCTAssertEqual(report.coverage.otherToolCalls, 1)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("private account"))
    }
}
