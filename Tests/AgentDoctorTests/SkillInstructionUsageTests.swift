import XCTest
@testable import AgentDoctor

final class SkillInstructionUsageTests: XCTestCase {
    let fixture = ToolUsageTests()
    let firstID = "00000000-0000-0000-0000-000000000001"
    let secondID = "00000000-0000-0000-0000-000000000002"
    func call(_ id: String = "skill", name: String = "fixture-skill") -> [String: Any] {
        ["type": "assistant", "timestamp": fixture.stamp(1), "message": ["content": [
            ["type": "tool_use", "id": id, "name": "Skill", "input": ["skill": name, "args": "private-input"]]
        ]]]
    }
    func load(_ id: String = "skill", uuid: String? = nil, text: String = "abcd", seconds: Double = 2) -> [String: Any] {
        ["type": "user", "timestamp": fixture.stamp(seconds), "isMeta": true,
         "uuid": uuid ?? firstID, "sourceToolUseID": id,
         "message": ["content": [["type": "text", "text": text]]]]
    }
    func testExplicitSourceLinkKeepsInstructionTextSeparateFromAcknowledgmentAndBilling() throws {
        var p = fixture.parser(); p.encoding = .cl100k
        p.consume(call(), host: "claude", session: "s")
        p.consume(load(), host: "claude", session: "s")
        p.end(host: "claude", session: "s", id: "skill", value: "ok", error: nil, time: fixture.start.addingTimeInterval(3))
        let report = p.report(), row = try XCTUnwrap(report.tools.first), loaded = try XCTUnwrap(row.skillInstructions)
        XCTAssertEqual(loaded.events, 1); XCTAssertEqual(loaded.textBytes, 4)
        XCTAssertEqual(loaded.referenceTokens, 1); XCTAssertEqual(loaded.incompleteEvents, 0)
        XCTAssertEqual(row.returnedTextBytes, 2); XCTAssertEqual(row.completed, 1)
        XCTAssertEqual(report.returnedTextSummary(kind: "skill").returnedTextBytes, 2)
        XCTAssertEqual(report.observedSkillInstructions?.textBytes, 4)
        XCTAssertTrue(report.sessionTokens.isEmpty)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("private-input"))
    }
    func testOutOfOrderAndMirroredEventsDeduplicateButDistinctRepeatedLoadsCount() throws {
        var p = fixture.parser()
        for event in [load(), load(), call(), load(uuid: secondID)] { p.consume(event, host: "claude", session: "s") }
        for _ in 0..<2 {
            let report = p.report(), loaded = try XCTUnwrap(report.tools.first?.skillInstructions)
            XCTAssertEqual(loaded.events, 2); XCTAssertEqual(loaded.textBytes, 8)
            XCTAssertEqual(report.coverage.unmatchedInstructionEvents, 0)
            XCTAssertEqual(report.tools.first?.missingResults, 1)
        }
        XCTAssertEqual(p.report().coverage.duplicateRecords, 1)
    }
    func testUnlinkedOrdinaryUserTextAndMetadataForOtherToolsNeverBecomeSkillInstructions() throws {
        var p = fixture.parser()
        p.consume(call(), host: "claude", session: "s")
        var ordinary = load(); ordinary["isMeta"] = false
        p.consume(ordinary, host: "claude", session: "s")
        var numeric = load(); numeric["isMeta"] = 1
        p.consume(numeric, host: "claude", session: "s")
        var missingLink = load(); missingLink.removeValue(forKey: "sourceToolUseID")
        p.consume(missingLink, host: "claude", session: "s")
        p.consume(fixture.call("mcp", "mcp__fixture__read", 1), host: "codex", session: "s")
        p.consume(load("mcp"), host: "claude", session: "s")
        p.consume(["type": "assistant", "timestamp": fixture.stamp(1), "message": ["content": [
            ["type": "tool_use", "id": "shell", "name": "Bash", "input": [:]]
        ]]], host: "claude", session: "s")
        p.consume(load("shell"), host: "claude", session: "s")
        XCTAssertEqual(p.report().observedSkillInstructions?.events, 0)
        XCTAssertEqual(p.report().coverage.unmatchedInstructionEvents, 1)
        XCTAssertFalse(p.report().complete)
    }
    func testSameIdentifierInDifferentSessionCannotAttachAndWindowsRemainBounded() throws {
        var p = fixture.parser()
        p.consume(call(), host: "claude", session: "a")
        p.consume(load(), host: "claude", session: "b")
        p.consume(load(seconds: -1), host: "claude", session: "a")
        p.consume(load(seconds: 101), host: "claude", session: "a")
        XCTAssertEqual(p.report().observedSkillInstructions?.events, 0)
        XCTAssertEqual(p.report().coverage.unmatchedInstructionEvents, 1)
        var invalid = load(); invalid.removeValue(forKey: "uuid")
        p.consume(invalid, host: "claude", session: "a")
        XCTAssertEqual(p.report().coverage.unmatchedInstructionEvents, 2)
    }
    func testMediaAndUnknownBlocksDoNotTokenizeDataAndKeepPartialReferenceUnknown() throws {
        var p = fixture.parser(); p.encoding = .cl100k
        p.consume(call(), host: "claude", session: "s")
        var event = load()
        event["message"] = ["content": [["type": "text", "text": "abcd"],
            ["type": "image", "data": "private-image-data"], ["type": "future", "data": "private-future"]]]
        p.consume(event, host: "claude", session: "s")
        let report = p.report(), loaded = try XCTUnwrap(report.observedSkillInstructions)
        XCTAssertEqual(loaded.textBytes, 4); XCTAssertEqual(loaded.nonTextBlocks, 2)
        XCTAssertEqual(loaded.incompleteEvents, 1); XCTAssertNil(loaded.referenceTokens)
        let exported = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(exported.contains("private-")); XCTAssertFalse(exported.contains("abcd"))
    }
    func testOldReportsKeepInstructionLoadingUnknownAndNewReportsRoundTrip() throws {
        var p = fixture.parser(); p.consume(call(), host: "claude", session: "s")
        p.consume(load(), host: "claude", session: "s")
        let data = try JSONEncoder().encode(p.report())
        XCTAssertEqual(try JSONDecoder().decode(ToolUsageReport.self, from: data).observedSkillInstructions?.events, 1)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        tools[0].removeValue(forKey: "skillInstructions"); object["tools"] = tools
        let old = try JSONDecoder().decode(ToolUsageReport.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.tools[0].skillInstructions); XCTAssertNil(old.observedSkillInstructions)
    }
    func testCategorySummaryDoesNotMixReferenceEncodings() throws {
        var p = fixture.parser(); p.encoding = .cl100k
        p.consume(call(), host: "claude", session: "s"); p.consume(load(), host: "claude", session: "s")
        var report = p.report(); report.tools[0].referenceEncoding = "o200k_base"
        XCTAssertNil(report.observedSkillInstructions)
    }
    func testInstructionSharesUseInstructionCountsAndRejectIncompleteOrUnknownLoads() throws {
        var p = fixture.parser(); p.encoding = .cl100k
        p.consume(call("small", name: "small"), host: "claude", session: "s")
        p.consume(load("small"), host: "claude", session: "s")
        p.consume(call("large", name: "large"), host: "claude", session: "s")
        p.consume(load("large"), host: "claude", session: "s")
        p.consume(load("large", uuid: secondID), host: "claude", session: "s")
        p.consume(call("unknown", name: "unknown"), host: "claude", session: "s")
        var report = p.report()
        let small = try XCTUnwrap(report.tools.first { $0.name == "small" })
        XCTAssertEqual(try XCTUnwrap(report.observedInstructionPercentage(of: small)), 100.0 / 3, accuracy: 0.0001)
        XCTAssertNil(report.observedInstructionPercentage(of: try XCTUnwrap(report.tools.first { $0.name == "unknown" })))
        report.tools[0].skillInstructions?.incompleteEvents = 1
        XCTAssertNil(report.observedInstructionPercentage(of: small))
    }
}
