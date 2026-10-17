import XCTest
@testable import AgentDoctor

final class UnattributedToolUsageTests: XCTestCase {
    private let fixture = ToolUsageTests()

    func testCodeModeBlocksExcludeMediaAndDoNotEnterMCPDenominator() throws {
        var parser = fixture.parser()
        let text = "done\n中文"
        let blocks: [[String: Any]] = [
            ["type": "input_text", "text": text],
            ["type": "input_image", "image_url": "data:image/png;base64," + String(repeating: "A", count: 100_000)],
            ["type": "input_audio", "input_audio": ["data": "fixture-private-audio", "format": "wav"]]
        ]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: blocks), as: UTF8.self)
        parser.consume(fixture.call("wrapped", "exec", 1), host: "codex", session: "a")
        parser.consume(fixture.output("wrapped", encoded, 2), host: "codex", session: "a")
        parser.consume(fixture.call("direct", "mcp__fixture__read", 1), host: "codex", session: "a")
        parser.consume(fixture.output("direct", "abcd", 2), host: "codex", session: "a")
        let report = parser.report(), other = try XCTUnwrap(report.coverage.unattributedResults)
        XCTAssertEqual(other.completed, 1); XCTAssertEqual(other.nonTextBlocks, 2)
        XCTAssertEqual(other.returnedTextBytes, text.utf8.count)
        XCTAssertEqual(other.returnedTextEstimatedTokens, TextFootprint(text).estimatedTokens)
        XCTAssertEqual(other.unmeasuredResults, 0)
        XCTAssertEqual(report.returnedTextSummary(kind: "mcp").returnedTextBytes, 4)
        XCTAssertEqual(report.tools.count, 1)
        let exported = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(exported.contains("fixture-private")); XCTAssertFalse(exported.contains("base64"))
        XCTAssertFalse(exported.contains("done")); XCTAssertFalse(exported.contains("中文"))
    }

    func testOutOfOrderDuplicateOrphanAndWindowBoundaries() throws {
        var parser = fixture.parser()
        let blocks = [["type": "input_text", "text": "abcd"], ["type": "input_image", "image_url": "private"]]
        parser.consume(fixture.output("wrapped", blocks, 2), host: "codex", session: "a")
        parser.consume(fixture.call("wrapped", "exec", 1), host: "codex", session: "a")
        parser.consume(fixture.output("wrapped", "duplicate", 3), host: "codex", session: "a")
        parser.consume(fixture.output("orphan", "orphan", 2), host: "codex", session: "a")
        parser.consume(fixture.call("outside", "exec", -1), host: "codex", session: "a")
        parser.consume(fixture.output("outside", "outside", 2), host: "codex", session: "a")
        parser.consume(fixture.call("late", "exec", 1), host: "codex", session: "a")
        parser.consume(fixture.output("late", "outside window", 101), host: "codex", session: "a")
        for _ in 0..<2 {
            let report = parser.report(), other = try XCTUnwrap(report.coverage.unattributedResults)
            XCTAssertEqual(report.coverage.otherToolCalls, 2)
            XCTAssertEqual(report.coverage.unmatchedResults, 1)
            XCTAssertEqual(other.completed, 1); XCTAssertEqual(other.missingResults, 1)
            XCTAssertEqual(other.returnedTextBytes, 4); XCTAssertEqual(other.nonTextBlocks, 1)
        }
    }

    func testJSONDataStaysTextAndUnrecognizedShapesRemainUnmeasured() throws {
        var parser = fixture.parser()
        let ordinaryJSON = #"[{"type":"customer","text":"business data"}]"#
        for (id, output) in [("json", ordinaryJSON as Any), ("unknown", ["unexpected": "private"] as Any),
                             ("malformed", [["type": "input_text"]] as Any)] {
            parser.consume(fixture.call(id, "exec", 1), host: "codex", session: "a")
            parser.consume(fixture.output(id, output, 2), host: "codex", session: "a")
        }
        let other = try XCTUnwrap(parser.report().coverage.unattributedResults)
        XCTAssertEqual(other.completed, 3); XCTAssertEqual(other.unmeasuredResults, 2)
        XCTAssertEqual(other.returnedTextBytes, ordinaryJSON.utf8.count)
    }

    func testUnknownModelBlockDoesNotTurnKnownMediaBackIntoText() throws {
        var parser = fixture.parser()
        let blocks: [[String: Any]] = [["type": "input_text", "text": "abcd"],
                                      ["type": "input_image", "image_url": "private-image-data"],
                                      ["type": "input_future", "data": "private-future-data"]]
        let encoded = " \n" + String(decoding: try JSONSerialization.data(withJSONObject: blocks), as: UTF8.self)
        parser.consume(fixture.call("wrapped", "exec", 1), host: "codex", session: "a")
        parser.consume(fixture.output("wrapped", encoded, 2), host: "codex", session: "a")
        let other = try XCTUnwrap(parser.report().coverage.unattributedResults)
        XCTAssertEqual(other.returnedTextBytes, 4); XCTAssertEqual(other.nonTextBlocks, 2)
        XCTAssertEqual(other.unmeasuredResults, 1)
    }

    func testReferenceCountAndUnknownReferenceAreIndependentOfHeuristic() throws {
        var parser = fixture.parser(); parser.encoding = .cl100k
        parser.consume(fixture.call("wrapped", "exec", 1), host: "codex", session: "a")
        parser.consume(fixture.output("wrapped", [["type": "input_text", "text": "abcd"]], 2), host: "codex", session: "a")
        var other = try XCTUnwrap(parser.report().coverage.unattributedResults)
        XCTAssertEqual(other.referenceReturnedTextTokens, 1)
        XCTAssertEqual(other.unavailableReferenceResults, 0)
        parser.consume(fixture.call("unknown", "exec", 1), host: "codex", session: "a")
        parser.consume(fixture.output("unknown", ["unexpected": "private"], 2), host: "codex", session: "a")
        other = try XCTUnwrap(parser.report().coverage.unattributedResults)
        XCTAssertNil(other.referenceReturnedTextTokens)
        XCTAssertEqual(other.unavailableReferenceResults, 1)
        XCTAssertEqual(other.returnedTextEstimatedTokens, 1)
    }

    func testOldReportDoesNotInventZeroAndNewReportRoundTrips() throws {
        let report = fixture.parser().report()
        let encoded = try JSONEncoder().encode(report)
        let fresh = try JSONDecoder().decode(ToolUsageReport.self, from: encoded)
        XCTAssertEqual(fresh.coverage.unattributedResults?.completed, 0)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var coverage = try XCTUnwrap(old["coverage"] as? [String: Any])
        coverage.removeValue(forKey: "unattributedResults"); old["coverage"] = coverage
        let decoded = try JSONDecoder().decode(ToolUsageReport.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.coverage.unattributedResults)
    }
}
