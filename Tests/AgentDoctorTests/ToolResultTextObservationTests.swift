import XCTest
@testable import AgentDoctor

final class ToolResultTextObservationTests: XCTestCase {
    private let media = #"{"content":[{"type":"image","data":"PRIVATE_MEDIA…559290 chars truncated…BBBB","mimeType":"image/png"}],"isError":true}"#
    private func parser() -> ToolUsageParser {
        ToolUsageParser(since: Date(timeIntervalSince1970: 0), until: Date(timeIntervalSince1970: 100))
    }
    private func add(_ value: Any, to parser: inout ToolUsageParser, id: String = "one", name: String = "mcp__owned__shot", endFirst: Bool = false) {
        if endFirst { parser.end(host: "codex", session: "s", id: id, value: value, error: false, time: Date(timeIntervalSince1970: 2)) }
        parser.start(host: "codex", session: "s", id: id, name: name, input: name == "Skill" ? ["skill":"owned-skill"] : nil, time: Date(timeIntervalSince1970: 1))
        parser.end(host: "codex", session: "s", id: id, value: value, error: false, time: Date(timeIntervalSince1970: 2))
    }
    func testSerializedMediaStaysLiteralTextWithSeparateRepresentationObservations() throws {
        var p = parser()
        add(["content": [["type": "text", "text": media]], "isError": false], to: &p)
        let r = p.report(), row = try XCTUnwrap(r.tools.first)
        XCTAssertEqual(row.serializedMediaTextResults, 1)
        XCTAssertEqual(row.serializedMediaTextBytes, media.utf8.count)
        XCTAssertEqual(row.truncationMarkerResults, 1)
        XCTAssertEqual(row.returnedTextBytes, media.utf8.count)
        XCTAssertEqual(row.returnedTextEstimatedTokens, TextFootprint(media).estimatedTokens)
        XCTAssertEqual(row.nonTextBlocks, 0)
        XCTAssertEqual(row.reportedErrors, 0) // Nested JSON's isError is still text.
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(r), as: UTF8.self).contains("PRIVATE_MEDIA"))
    }
    func testNativeMediaAndTopLevelEncodedEnvelopeAreNotMisreportedAsText() throws {
        let image: [String: Any] = ["type": "image", "data": "PRIVATE_MEDIA…12 chars truncated…", "mimeType": "image/png"]
        for value in [ ["content": [image]] as Any,
                       String(decoding: try JSONSerialization.data(withJSONObject: ["content": [image]]), as: UTF8.self) as Any ] {
            var p = parser(); add(value, to: &p)
            let row = try XCTUnwrap(p.report().tools.first)
            XCTAssertEqual(row.serializedMediaTextResults, 0)
            XCTAssertEqual(row.serializedMediaTextBytes, 0)
            XCTAssertEqual(row.truncationMarkerResults, 0)
            XCTAssertEqual(row.returnedTextBytes, 0)
            XCTAssertEqual(row.nonTextBlocks, 1)
        }
    }
    func testCountsResultsOnceDespiteMultipleBlocksDuplicatesAndOutOfOrderRecords() throws {
        var p = parser()
        let value: [String: Any] = ["content": [["type": "text", "text": media], ["type": "text", "text": media]]]
        add(value, to: &p, endFirst: true)
        let row = try XCTUnwrap(p.report().tools.first)
        XCTAssertEqual(row.completed, 1)
        XCTAssertEqual(row.serializedMediaTextResults, 1)
        XCTAssertEqual(row.truncationMarkerResults, 1)
        XCTAssertEqual(row.returnedTextBytes, media.utf8.count * 2 + 1)
        XCTAssertEqual(row.serializedMediaTextBytes, media.utf8.count * 2 + 1)
    }
    func testNormalTextAndMalformedMediaDoNotGetGuessedIntoWarnings() {
        for text in ["truncated image", "… chars truncated…", "…0 chars truncated…", "{bad json}", #"{"type":"image","data":"text"}"#, #"{"content":[{"type":"text","text":"image"}]}"#] {
            let observation = ToolResultTextObservation(["content": [["type": "text", "text": text]]], codexInputBlocks: false)
            XCTAssertFalse(observation.serializedMedia, text)
            XCTAssertFalse(observation.truncationMarker, text)
        }
        let truncated = ToolResultTextObservation("plain …42 chars truncated… text", codexInputBlocks: false)
        XCTAssertTrue(truncated.truncationMarker)
        XCTAssertFalse(truncated.serializedMedia)
    }
    func testCodexOuterTextAndImageStaySeparateAndNeverBecomeMCPAttribution() throws {
        var p = parser()
        let blocks: [[String: Any]] = [["type": "input_text", "text": media], ["type": "input_image", "image_url": "data:image/png;base64,PRIVATE_IMAGE"]]
        let output = String(decoding: try JSONSerialization.data(withJSONObject: blocks), as: UTF8.self)
        add(output, to: &p, name: "functions.exec")
        let report = p.report(), row = try XCTUnwrap(report.coverage.unattributedResults?.byTool?.first)
        XCTAssertTrue(report.tools.isEmpty)
        XCTAssertEqual(row.serializedMediaTextResults, 1)
        XCTAssertEqual(row.truncationMarkerResults, 1)
        XCTAssertEqual(row.nonTextBlocks, 1)
        XCTAssertEqual(row.returnedTextBytes, media.utf8.count)
        XCTAssertEqual(row.serializedMediaTextBytes, media.utf8.count)
    }
    func testMediaResultByteSplitIncludesAccompanyingTextAndExcludesOtherResults() throws {
        for name in ["mcp__owned__shot", "functions.exec", "Skill"] {
            var p = parser()
            add(["content": [["type": "text", "text": media], ["type": "text", "text": "附带文字"]]], to: &p, id: "media", name: name)
            add("plain", to: &p, id: "plain", name: name)
            let report = p.report(), row = try XCTUnwrap(name == "functions.exec" ? report.coverage.unattributedResults?.byTool?.first : report.tools.first)
            let mediaBytes = media.utf8.count + 1 + "附带文字".utf8.count
            XCTAssertEqual(row.serializedMediaTextResults, 1)
            XCTAssertEqual(row.serializedMediaTextBytes, mediaBytes)
            XCTAssertEqual(row.observedSerializedMediaTextBytes, mediaBytes)
            XCTAssertEqual(row.returnedTextBytes, mediaBytes + 5)
            XCTAssertTrue(row.serializedMediaTextCompositionLine?.contains("other result text: 5 bytes") == true)
        }
    }
    func testPartialOuterResultKeepsMediaByteSplitUnknownAcrossLaterResults() throws {
        var p = parser()
        add([["type":"input_text", "text":media], ["type":"unknown_block"]], to: &p, id:"partial", name:"functions.exec")
        add([["type":"input_text", "text":media]], to: &p, id:"complete", name:"functions.exec")
        let row = try XCTUnwrap(p.report().coverage.unattributedResults?.byTool?.first)
        XCTAssertEqual(row.serializedMediaTextResults, 2)
        XCTAssertNil(row.serializedMediaTextBytes)
        XCTAssertNil(row.observedSerializedMediaTextBytes)
        XCTAssertTrue(row.serializedMediaTextCompositionLine?.contains("unavailable or inconsistent") == true)
        XCTAssertEqual(row.returnedTextBytes, media.utf8.count * 2)
    }
    func testLegacyAndInconsistentMediaByteSplitsNeverBecomeKnownZero() throws {
        var p = parser(); add(["content": [["type":"text", "text":media]]], to: &p)
        let known = try XCTUnwrap(p.report().tools.first)
        var legacy = known; legacy.serializedMediaTextBytes = nil
        let decoded = try JSONDecoder().decode(ToolUsageRow.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.observedSerializedMediaTextBytes)
        for bytes in [-1, 0, known.returnedTextBytes + 1] {
            var bad = known; bad.serializedMediaTextBytes = bytes
            XCTAssertNil(bad.observedSerializedMediaTextBytes)
        }
        var bad = known; bad.serializedMediaTextResults = 0
        XCTAssertNil(bad.observedSerializedMediaTextBytes)
        bad = known; bad.serializedMediaTextResults = known.completed + 1
        XCTAssertNil(bad.observedSerializedMediaTextBytes)
    }
    func testExecutionLimitDeclarationsDoNotChangeAccountingOrErrorStatus() throws {
        for text in ["Warning: truncated output (original token count: 54321)\nretained text",
                     "Output exceeded the available model context and was truncated."] {
            var p = parser()
            p.start(host: "codex", session: "s", id: "one", name: "functions.exec", input: nil, time: Date(timeIntervalSince1970: 1))
            p.end(host: "codex", session: "s", id: "one", value: [["type":"input_text", "text":text]], error: nil, time: Date(timeIntervalSince1970: 2))
            let report = p.report(), row = try XCTUnwrap(report.coverage.unattributedResults?.byTool?.first)
            XCTAssertEqual(row.truncationMarkerResults, 1)
            XCTAssertEqual(row.returnedTextBytes, text.utf8.count)
            XCTAssertEqual(row.returnedTextEstimatedTokens, TextFootprint(text).estimatedTokens)
            XCTAssertEqual(row.reportedErrors, 0); XCTAssertEqual(row.unknownErrorStatus, 1)
            XCTAssertEqual(row.serializedMediaTextResults, 0)
            XCTAssertTrue(report.tools.isEmpty)
        }
    }
    func testExecutionDeclarationsCountOnceAcrossBlocksAndNeverScanNativeMedia() throws {
        let warning = "Warning: truncated output (original token count: 9876)"
        let context = "Output exceeded the available model context and was truncated."
        var p = parser()
        add([["type":"input_text", "text":warning], ["type":"input_text", "text":context],
             ["type":"input_image", "image_url":"data:image/png;base64," + warning]], to: &p, name:"functions.exec", endFirst:true)
        let row = try XCTUnwrap(p.report().coverage.unattributedResults?.byTool?.first)
        XCTAssertEqual(row.truncationMarkerResults, 1)
        XCTAssertEqual(row.nonTextBlocks, 1)
        let native = ToolResultTextObservation(["content":[["type":"image", "data":context,"mimeType":"image/png"]]], codexInputBlocks:false)
        XCTAssertFalse(native.truncationMarker)
        for text in ["truncated output", "Warning: truncated output (original token count: 0)",
                     "Warning: truncated output (original token count: N)",
                     "Warning: truncated output (original token count: -1)",
                     "Warning: truncated output (original token count: 12",
                     "Output exceeded the available model context"] {
            XCTAssertFalse(ToolResultTextObservation(text,codexInputBlocks:true).truncationMarker,text)
        }
    }
    func testOldRowFieldsStayUnmeasuredAndRoundTripNewObservations() throws {
        var row = ToolUsageRow(id: "one", host: "codex", kind: "mcp", name: "shot")
        let old = try JSONDecoder().decode(ToolUsageRow.self, from: JSONEncoder().encode(row))
        XCTAssertNil(old.serializedMediaTextResults)
        XCTAssertNil(old.truncationMarkerResults)
        row.serializedMediaTextResults = 2; row.truncationMarkerResults = 1
        let current = try JSONDecoder().decode(ToolUsageRow.self, from: JSONEncoder().encode(row))
        XCTAssertEqual(current.serializedMediaTextResults, 2)
        XCTAssertEqual(current.truncationMarkerResults, 1)
    }
}
