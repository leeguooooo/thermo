import XCTest
@testable import AgentDoctor

final class SkillFrontMatterTests: XCTestCase {
    func document(_ header: String) -> String { "---\n" + header + "\n---\nBody instructions." }

    func testYAMLCommentsAndQuotedHashHaveDifferentCatalogContents() {
        XCTAssertEqual(ConfigChecks.frontMatter(document("name: sample\ndescription: send to #channel ignored"))?["description"], "send to")
        XCTAssertEqual(ConfigChecks.frontMatter(document("name: sample\ndescription: 'send to #channel'"))?["description"], "send to #channel")
        XCTAssertEqual(ConfigChecks.frontMatter(document("name: sample\ndescription: Read https://example.invalid/#part"))?["description"], "Read https://example.invalid/#part")
    }

    func testQuotedEscapesMultilinePlainAndScalarChompingUseYAMLValues() {
        XCTAssertEqual(ConfigChecks.frontMatter(document("name: sample\ndescription: " + #""Use \"quoted\" words and \nline""#))?["description"], "Use \"quoted\" words and \nline")
        XCTAssertEqual(ConfigChecks.frontMatter(document("name: sample\ndescription: Read first\n  and second"))?["description"], "Read first and second")
        XCTAssertEqual(ConfigChecks.frontMatter(document("name: sample\ndescription: |-\n  first\n  second"))?["description"], "first\nsecond")
        XCTAssertEqual(ConfigChecks.frontMatter(document("name: sample\ndescription: >\n  first\n  second"))?["description"], "first second\n")
    }

    func testIndentedSeparatorInsideLiteralDescriptionDoesNotEndTheHeader() {
        let text = document("name: sample\ndescription: |-\n  first\n  ---\n  second")
        XCTAssertEqual(ConfigChecks.frontMatter(text)?["description"], "first\n---\nsecond")
        XCTAssertEqual(ConfigChecks.skillBody(text), "Body instructions.")
    }

    func testInvalidYAMLDuplicateKeysAndNonStringFieldsNeverBecomeAValidCatalog() {
        for header in ["name: sample\ndescription: Tool: run", "name: sample\ndescription: first\ndescription: second",
                       "name: sample\ndescription: [first, second]", "name: sample\ndescription: false",
                       "name: 12\ndescription: text", "[name, description]", "name: sample\ndescription: !!custom text"] {
            let parsed = SkillFrontMatter.parse(document(header))
            XCTAssertNil(parsed.fields, header); XCTAssertEqual(parsed.issue?.code, "invalid_front_matter", header)
        }
    }

    func testBOMCRLFAndMetadataAreSupportedWithoutConstructingNestedObjects() {
        let text = "\u{feff}" + document("name: sample\ndescription: text\nmetadata:\n  nested: [a, b]\n  other: !!custom value").replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(SkillFrontMatter.parse(text).fields, ["name":"sample", "description":"text"])
        XCTAssertNil(SkillFrontMatter.parse(text).issue)
        XCTAssertEqual(ConfigChecks.skillBody(text), "Body instructions.")
    }

    func testNestedMetadataRemainsBoundedAndIsNotExpandedIntoSwiftObjects() {
        let aliases = "metadata:\n  a: &a [x, x]\n" + (1...25).map { "  v\($0): &v\($0) [*\($0 == 1 ? "a" : "v" + String($0 - 1)), *\($0 == 1 ? "a" : "v" + String($0 - 1))]" }.joined(separator: "\n")
        let parsed = SkillFrontMatter.parse(document("name: sample\ndescription: text\n" + aliases))
        XCTAssertEqual(parsed.fields?["description"], "text")
        XCTAssertNil(parsed.issue)
        let deep = "name: sample\ndescription: text\nmetadata: " + String(repeating: "[", count: 1_100) + "x" + String(repeating: "]", count: 1_100)
        XCTAssertEqual(SkillFrontMatter.parse(document(deep)).issue?.code, "invalid_front_matter")
    }

    func testHeaderBudgetMissingDelimiterAndParserErrorsDoNotExportPrivateLines() throws {
        XCTAssertEqual(SkillFrontMatter.parse(document("name: sample\ndescription: " + String(repeating:"a", count:65_536))).issue?.code, "front_matter_limit")
        XCTAssertEqual(SkillFrontMatter.parse("---\nname: sample").issue?.code, "invalid_front_matter")
        let value = SkillFrontMatter.parse(document("name: sample\ndescription: PRIVATE_PAYLOAD: secret"))
        let exported = String(decoding: try JSONEncoder().encode(value.issue), as: UTF8.self)
        XCTAssertFalse(exported.contains("PRIVATE_PAYLOAD")); XCTAssertFalse(exported.contains("secret"))
        XCTAssertNil(SkillFrontMatter.parse("Body without front matter").fields)
    }

    func testInvalidCatalogCannotBecomeZeroOrAnExactSummaryWhileDocumentRemainsMeasured() throws {
        let fixture = ContextFootprintTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let text = document("name: sample\ndescription: Tool: run")
        try fixture.write(".agents/skills/sample/SKILL.md", text)
        let checks = fixture.scan(), item = try XCTUnwrap(checks.items.first), footprint = try XCTUnwrap(item.skillFootprint)
        XCTAssertEqual(footprint.catalog.measurementComplete, false)
        XCTAssertNil(footprint.catalog.comparisonTokens); XCTAssertNil(footprint.catalog.referenceTokens)
        XCTAssertEqual(footprint.document.bytes, text.utf8.count)
        XCTAssertEqual(footprint.quality?.issues.first?.code, "invalid_front_matter")
        let summary = try XCTUnwrap(SkillContextSummary.summarize(checks.items).first)
        XCTAssertNil(summary.catalogEstimatedTokens)
        XCTAssertEqual(summary.documentBytes, text.utf8.count)
        let roundTrip = try JSONDecoder().decode(SkillContextSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertNil(roundTrip.catalogEstimatedTokens)
    }
}
