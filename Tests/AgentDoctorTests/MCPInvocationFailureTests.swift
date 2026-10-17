import XCTest
@testable import AgentDoctor

final class MCPInvocationFailureTests: XCTestCase {
    let fixture = ToolUsageTests()

    func failure(_ id: String, message: Any = "fixture-private-host-error", status: String = "failed") -> [String: Any] {
        var event = fixture.native(id)
        var payload = event["payload"] as! [String: Any]
        var item = payload["item"] as! [String: Any]
        item["result"] = NSNull(); item["status"] = status; item["error"] = ["message": message]
        payload["item"] = item; event["payload"] = payload
        return event
    }

    func testTypedHostFailureClosesCallWithoutInventingResultStatus() throws {
        var parser = fixture.parser()
        parser.consume(failure("failed"), host: "codex", session: "a")
        parser.consume(failure("failed"), host: "codex", session: "a")
        let report = parser.report(), row = try XCTUnwrap(report.tools.first)
        XCTAssertEqual(row.calls, 1); XCTAssertEqual(row.completed, 0)
        XCTAssertEqual(row.invocationFailures, 1); XCTAssertEqual(row.missingResults, 0)
        XCTAssertEqual(row.reportedErrors, 0); XCTAssertEqual(row.unknownErrorStatus, 0)
        XCTAssertEqual(row.knownStatusResults, 0); XCTAssertNil(row.explicitErrorRate)
        XCTAssertEqual(row.returnedTextBytes, 0); XCTAssertEqual(row.timingSamples, 1)
        XCTAssertEqual(row.totalObservedSeconds, 2); XCTAssertEqual(row.medianSeconds, 2)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("fixture-private"))
    }

    func testLifecycleAndMalformedErrorsDoNotInventFailures() throws {
        for (message, status) in [(NSNull() as Any, "failed"), (true as Any, "failed"),
                                  ("" as Any, "failed"), (" \n" as Any, "failed"),
                                  ("error" as Any, "completed")] {
            var parser = fixture.parser()
            parser.consume(failure("unknown", message: message, status: status), host: "codex", session: "a")
            let row = try XCTUnwrap(parser.report().tools.first)
            XCTAssertEqual(row.invocationFailures, 0); XCTAssertEqual(row.missingResults, 1)
            XCTAssertEqual(row.timingSamples, 0)
        }
        var parser = fixture.parser()
        var event = failure("missing-error")
        var payload = event["payload"] as! [String: Any]; var item = payload["item"] as! [String: Any]
        item.removeValue(forKey: "error"); payload["item"] = item; event["payload"] = payload
        parser.consume(event, host: "codex", session: "a")
        XCTAssertEqual(parser.report().tools.first?.missingResults, 1)
    }

    func testHostFailureDoesNotChangeMCPResultErrorDenominatorOrReferenceText() throws {
        var parser = fixture.parser(); parser.encoding = .cl100k
        for (id, error) in [("success", false), ("application", true)] {
            parser.consume(fixture.native(id, result: ["isError": error, "content": [["type": "text", "text": "abcd"]]]), host: "codex", session: "a")
        }
        parser.consume(failure("protocol"), host: "codex", session: "a")
        let report = parser.report(), row = try XCTUnwrap(report.tools.first)
        XCTAssertEqual(row.calls, 3); XCTAssertEqual(row.completed, 2)
        XCTAssertEqual(row.invocationFailures, 1); XCTAssertEqual(row.missingResults, 0)
        XCTAssertEqual(row.reportedErrors, 1); XCTAssertEqual(row.explicitErrorRate, 0.5)
        XCTAssertEqual(row.timingSamples, 3)
        XCTAssertEqual(row.referenceReturnedTextTokens, 2)
        XCTAssertEqual(report.returnedTextSummary(kind: "mcp").returnedTextBytes, 8)
        XCTAssertEqual(report.returnedTextSummary(kind: "mcp").returnedTextTokens, 2)
    }

    func testPresentResultTakesPrecedenceAndInvalidEndTimeDoesNotInventTiming() throws {
        var parser = fixture.parser()
        var event = failure("both")
        var payload = event["payload"] as! [String: Any]; var item = payload["item"] as! [String: Any]
        item["result"] = ["isError": false, "content": []]; payload["item"] = item; event["payload"] = payload
        parser.consume(event, host: "codex", session: "a")
        var row = try XCTUnwrap(parser.report().tools.first)
        XCTAssertEqual(row.completed, 1); XCTAssertEqual(row.invocationFailures, 0)
        var invalid = failure("invalid")
        payload = invalid["payload"] as! [String: Any]; payload["completed_at_ms"] = true; invalid["payload"] = payload
        var other = fixture.parser(); other.consume(invalid, host: "codex", session: "a")
        row = try XCTUnwrap(other.report().tools.first)
        XCTAssertEqual(row.invocationFailures, 0); XCTAssertEqual(row.missingResults, 1)
        XCTAssertEqual(row.timingSamples, 0); XCTAssertFalse(other.report().complete)
    }

    func testOldReportKeepsInvocationFailureCountUnknown() throws {
        var parser = fixture.parser(); parser.consume(failure("failed"), host: "codex", session: "a")
        let encoded = try JSONEncoder().encode(parser.report())
        XCTAssertEqual(try JSONDecoder().decode(ToolUsageReport.self, from: encoded).tools.first?.invocationFailures, 1)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var rows = old["tools"] as! [[String: Any]]; rows[0].removeValue(forKey: "invocationFailures"); old["tools"] = rows
        let decoded = try JSONDecoder().decode(ToolUsageReport.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.tools.first?.invocationFailures)
    }
}
