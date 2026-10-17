import XCTest
@testable import AgentDoctor

final class CodexCLIUsageTests: XCTestCase {
    let fixture = ToolUsageTests()
    func completion(_ id: String = "cli", result: Any = ["Ok": ["content": [["type": "text", "text": "abcd"],
        ["type": "image", "data": "private-base64", "mimeType": "image/png"]], "isError": false]],
        duration: Any = ["secs": 1, "nanos": 500_000_000], seconds: Double = 3) -> [String: Any] {
        fixture.event("event_msg", ["type": "mcp_tool_call_end", "call_id": id,
            "invocation": ["server": "fixture", "tool": "echo", "arguments": ["private": "private-input"]],
            "duration": duration, "result": result], seconds)
    }
    func testCompletionOnlyCLIEventMeasuresMediaWithoutTokenizingBase64() throws {
        var parser = fixture.parser(); parser.encoding = .cl100k
        parser.consume(completion(), host: "codex", session: "session")
        let report = parser.report(), row = try XCTUnwrap(report.tools.first)
        XCTAssertEqual(row.calls, 1); XCTAssertEqual(row.completed, 1)
        XCTAssertEqual(row.server, "fixture"); XCTAssertEqual(row.name, "echo")
        XCTAssertEqual(row.returnedTextBytes, 4); XCTAssertEqual(row.referenceReturnedTextTokens, 1)
        XCTAssertEqual(row.nonTextBlocks, 1); XCTAssertEqual(row.medianSeconds, 1.5)
        XCTAssertEqual(row.explicitErrorRate, 0)
        XCTAssertEqual(report.coverage.missingTimestamps, 0)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("private"))
    }
    func testCLIErrAndMCPIsErrorHaveSeparateDenominators() throws {
        var parser = fixture.parser()
        parser.consume(completion("host", result: ["Err": "private-host-error"]), host: "codex", session: "s")
        parser.consume(completion("result", result: ["Ok": ["content": [], "isError": true]]), host: "codex", session: "s")
        let row = try XCTUnwrap(parser.report().tools.first)
        XCTAssertEqual(row.calls, 2); XCTAssertEqual(row.completed, 1)
        XCTAssertEqual(row.invocationFailures, 1); XCTAssertEqual(row.reportedErrors, 1)
        XCTAssertEqual(row.explicitErrorRate, 1); XCTAssertEqual(row.timingSamples, 2)
        XCTAssertEqual(row.missingResults, 0)
    }
    func testImageSerializedInsideTextRemainsTextAsActuallyLogged() throws {
        var parser = fixture.parser()
        let text = #"{"content":[{"type":"image","data":"private-base64","mimeType":"image/png"}],"isError":false}"#
        parser.consume(completion(result: ["Ok": ["content": [["type": "text", "text": text]], "isError": false]]), host: "codex", session: "s")
        let row = try XCTUnwrap(parser.report().tools.first)
        XCTAssertEqual(row.returnedTextBytes, text.utf8.count)
        XCTAssertEqual(row.nonTextBlocks, 0)
    }
    func testInvalidOrMissingDurationKeepsCallButDoesNotInventZeroLatency() throws {
        for duration: Any in [NSNull(), ["secs": true, "nanos": 0], ["secs": -1, "nanos": 0],
                              ["secs": 0, "nanos": 1_000_000_000], ["secs": 0.5, "nanos": 0]] {
            var parser = fixture.parser()
            parser.consume(completion(duration: duration), host: "codex", session: "s")
            let report = parser.report(), row = try XCTUnwrap(report.tools.first)
            XCTAssertEqual(row.completed, 1); XCTAssertEqual(row.timingSamples, 0)
            XCTAssertNil(row.medianSeconds); XCTAssertFalse(report.complete)
        }
    }
    func testBeginAndLegacyRecordsDeduplicateWithCLICompletionInEitherOrder() throws {
        let result: [String: Any] = ["content": [["type": "text", "text": "abcd"]], "isError": false]
        let legacy = [fixture.call("cli", "mcp__fixture__echo", 1), fixture.output("cli", result, 3)]
        let native = completion(result: ["Ok": result], duration: ["secs": 2, "nanos": 0])
        for events in [legacy + [native, native], [native] + legacy] {
            var parser = fixture.parser()
            events.forEach { parser.consume($0, host: "codex", session: "s") }
            let row = try XCTUnwrap(parser.report().tools.first)
            XCTAssertEqual(row.calls, 1); XCTAssertEqual(row.completed, 1)
            XCTAssertEqual(row.returnedTextBytes, 4); XCTAssertEqual(row.medianSeconds, 2)
        }
        var parser = fixture.parser()
        parser.consume(fixture.event("event_msg", ["type": "mcp_tool_call_begin", "call_id": "cli",
            "invocation": ["server": "fixture", "tool": "echo"]], 1), host: "codex", session: "s")
        parser.consume(completion(duration: NSNull()), host: "codex", session: "s")
        XCTAssertEqual(parser.report().tools.first?.medianSeconds, 2)
    }
    func testWindowAndAmbiguousResultDoNotBecomeSuccessfulCalls() throws {
        var parser = fixture.parser()
        parser.consume(completion("outside", seconds: -1), host: "codex", session: "s")
        parser.consume(completion("ambiguous", result: ["Ok": ["content": []], "Err": "error"]), host: "codex", session: "s")
        let row = try XCTUnwrap(parser.report().tools.first)
        XCTAssertEqual(row.calls, 1); XCTAssertEqual(row.completed, 0)
        XCTAssertEqual(row.missingResults, 1); XCTAssertNil(row.explicitErrorRate)
    }
}
