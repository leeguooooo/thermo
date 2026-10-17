import XCTest
@testable import AgentDoctor

final class SkillQualitySummaryTests: XCTestCase {
    func item(_ id: String, file: String? = "file", agent: String = "codex", scope: String = "user") throws -> AgentItem {
        let data = #"{"id":"fixture","area":"skills","agent":"codex","name":"fixture","detail":"fixture","enabled":true,"actions":[]}"#.data(using: .utf8)!
        var item = try JSONDecoder().decode(AgentItem.self, from: data)
        item.id = id; item.agent = agent
        var quality = SkillQualityReport()
        quality.checkedLocalReferences = 1
        quality.issues = [SkillQualityIssue(code: "missing_local_reference", line: 1, target: "missing.md", message: "fixture")]
        item.skillFootprint = SkillFootprint(catalog: TextFootprint("fixture"), document: TextFootprint("fixture"), body: TextFootprint("fixture"), sourcePath: "fixture", contentHash: "hash", canonicalID: file, scope: scope, quality: quality)
        return item
    }

    func testAliasesCountOnceAndCacheEvidenceStaysSeparate() throws {
        let main = try item("main"), alias = try item("alias", agent: "shared")
        let cache = try item("cache", agent: "codex-cache", scope: "cache")
        let summaries = SkillQualitySummary.summarize([main, alias, cache])
        XCTAssertEqual(summaries.count, 2)
        let directory = try XCTUnwrap(summaries.first { $0.scope == "directory" })
        XCTAssertEqual(directory.uniqueFiles, 1); XCTAssertEqual(directory.inspectedFiles, 1)
        XCTAssertEqual(directory.aliases, 1); XCTAssertEqual(directory.findings, 1)
        XCTAssertEqual(directory.checkedLocalReferences, 1)
        let cached = try XCTUnwrap(summaries.first { $0.scope == "cache" })
        XCTAssertEqual(cached.checkedLocalReferences, 1); XCTAssertEqual(cached.findings, 1)
    }

    func testIdenticalIndependentCopiesAndDifferentHostsAreNotCollapsed() throws {
        let first = try item("first"), second = try item("second", file: "other")
        let claude = try item("claude", agent: "claude"), plugin = try item("plugin", agent: "plugin", scope: "plugin")
        let summaries = SkillQualitySummary.summarize([first, second, claude, plugin])
        XCTAssertEqual(summaries.first { $0.host == "codex" }?.uniqueFiles, 2)
        XCTAssertEqual(summaries.first { $0.host == "codex" }?.findings, 2)
        XCTAssertEqual(summaries.first { $0.host == "claude" }?.uniqueFiles, 1)
        XCTAssertEqual(summaries.first { $0.host == "claude" }?.aliases, 1)
    }

    func testMissingEvidenceAndUnknownIdentitiesAreExplicitExclusions() throws {
        var missing = try item("missing"); missing.skillFootprint?.quality = nil
        let unknown = try item("unknown", file: nil)
        var unmeasured = try item("unmeasured"); unmeasured.skillFootprint = nil
        let summary = try XCTUnwrap(SkillQualitySummary.summarize([missing, unknown, unmeasured]).first)
        XCTAssertEqual(summary.inspectedFiles, 0)
        XCTAssertEqual(summary.unavailableFiles, 1)
        XCTAssertEqual(summary.unverifiedIdentityEntries, 1)
        XCTAssertEqual(summary.unmeasuredEntries, 1)
        XCTAssertEqual(summary.findings, 0)
    }

    func testConflictingContentOrQualityNeverChoosesAnArbitraryAlias() throws {
        let main = try item("main")
        var alias = try item("alias"); alias.skillFootprint?.contentHash = "changed"
        var summary = try XCTUnwrap(SkillQualitySummary.summarize([main, alias]).first)
        XCTAssertEqual(summary.conflictingFiles, 1); XCTAssertEqual(summary.inspectedFiles, 0)
        alias.skillFootprint?.contentHash = "hash"; alias.skillFootprint?.quality?.issues = []
        summary = try XCTUnwrap(SkillQualitySummary.summarize([main, alias]).first)
        XCTAssertEqual(summary.conflictingFiles, 1); XCTAssertEqual(summary.findings, 0)
        alias.skillFootprint?.quality = nil
        summary = try XCTUnwrap(SkillQualitySummary.summarize([main, alias]).first)
        XCTAssertEqual(summary.unavailableFiles, 1); XCTAssertEqual(summary.inspectedFiles, 0)
    }

    func testIncompleteEvidenceRemainsIncompleteAndNonSkillsAreExcluded() throws {
        var partial = try item("partial"); partial.skillFootprint?.quality?.complete = false
        var other = try item("other"); other.area = .mcp
        let summary = try XCTUnwrap(SkillQualitySummary.summarize([partial, other]).first)
        XCTAssertEqual(summary.entries, 1); XCTAssertEqual(summary.incompleteInspections, 1)
        XCTAssertEqual(summary.checkedLocalReferences, 1)
        XCTAssertTrue(SkillQualitySummary.summarize([]).isEmpty)
    }

    func testOldContextReportsDecodeWithoutQualitySummaries() throws {
        let report = ContextInventory(generated: Date(), skills: [], mcpServers: [], findings: [], cancelled: false, coverageNote: "", measurementNote: "", mcpNote: "")
        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(ContextInventory.self, from: encoded)
        XCTAssertNil(decoded.qualitySummaries)
    }
}
