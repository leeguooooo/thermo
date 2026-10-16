import XCTest
import ThermoL10n
@testable import AgentDoctor

final class SkillQualityTests: XCTestCase {
    var root: URL!
    var language: Language?
    override func setUpWithError() throws {
        language = L10n.override; L10n.override = .english
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        L10n.override = language
        try FileManager.default.removeItem(at: root)
    }
    func inspect(_ body: String) -> SkillQualityReport {
        SkillQuality.inspect("---\nname: fixture\ndescription: fixture\n---\n" + body, at: root.appendingPathComponent("SKILL.md"))
    }
    func testMissingLinksHaveOriginalSourceLinesAndEncodedSpacesResolve() throws {
        try "fixture".write(to: root.appendingPathComponent("existing guide.md"), atomically: true, encoding: .utf8)
        let result = inspect("[present](existing%20guide.md)\n[missing](references/missing.md#section)\n[again](references/missing.md)")
        XCTAssertEqual(result.checkedLocalReferences, 2)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertEqual(result.issues.first?.line, 6)
        XCTAssertEqual(result.issues.first?.target, "references/missing.md")
    }
    func testExamplesInlineCodeAndCommentsDoNotBecomeMissingFiles() {
        let result = inspect("""
        ```markdown
        <!-- comment syntax inside a code example
        [example](not-real.md)
        ```
        `[inline](also-not-real.md)`
        <!-- [comment](hidden.md) -->
            [indented example](indented.md)
        [real](actual-missing.md)
        """)
        XCTAssertEqual(result.issues.map(\.target), ["actual-missing.md"])
        XCTAssertEqual(result.checkedLocalReferences, 1)
    }
    func testFullReferenceLinksAndImagesAreCheckedButUnboundProseIsNot() {
        let result = inspect("[Guide][guide]\n![image](assets/missing.png)\n[prose][unbound]\n\n[guide]: <references/guide.md> \"Title\"")
        XCTAssertEqual(Set(result.issues.compactMap(\.target)), ["assets/missing.png", "references/guide.md"])
        XCTAssertEqual(result.checkedLocalReferences, 2)
    }
    func testRemoteAbsoluteDynamicAndAnchorTargetsAreNotContacted() {
        let result = inspect("[web](https://example.invalid/missing.md)\n[absolute](/missing.md)\n[dynamic](${ROOT}/missing.md)\n[anchor](#title)\n[glob](references/*.md)")
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.checkedLocalReferences, 0)
        XCTAssertGreaterThanOrEqual(result.skippedReferences, 4)
    }
    func testEncodedControlCharactersAreNotExportedAsTargets() throws {
        let result = inspect("[target](references/%1Bbad.md)")
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.checkedLocalReferences, 0)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("\u{1b}"))
    }
    func testEmptyBodyAndCommentOnlyBodyAreReportedWithoutLengthScoring() {
        XCTAssertEqual(inspect("\n<!-- no instructions -->\n").issues.first?.code, "empty_body")
        XCTAssertTrue(inspect(String(repeating: "Use this instruction.\n", count: 5000)).issues.isEmpty)
    }
    func testManyBracketCharactersDoNotCauseQuadraticRegexSearch() {
        let started = Date()
        let result = inspect(String(repeating: "[", count: 100_000))
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
    func testReferenceBudgetAndCancellationAreExplicit() {
        let body = (0..<600).map { "[file](missing-\($0).md)" }.joined(separator: "\n")
        let result = inspect(body)
        XCTAssertEqual(result.checkedLocalReferences, 512)
        XCTAssertFalse(result.complete)
        let stopped = SkillQuality.inspect(body, at: root.appendingPathComponent("SKILL.md"), cancelled: { true })
        XCTAssertFalse(stopped.complete)
        XCTAssertEqual(stopped.checkedLocalReferences, 0)
    }
    func testCommonMarkShortcutReferenceAndNestedParenthesesAreResolved() throws {
        try "fixture".write(to: root.appendingPathComponent("guide(v2).md"), atomically: true, encoding: .utf8)
        let result = inspect("[shortcut]\n[nested](guide(v2).md)\n\n[shortcut]: references/missing.md")
        XCTAssertEqual(result.checkedLocalReferences, 2)
        XCTAssertEqual(result.issues.first?.target, "references/missing.md")
        XCTAssertEqual(result.issues.count, 1)
    }
    func testParentReferencesUseTheSymlinkTargetDirectory() throws {
        let source = root.appendingPathComponent("parent/skill")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "fixture".write(to: root.appendingPathComponent("parent/guide.md"), atomically: true, encoding: .utf8)
        try "[guide](../guide.md)".write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let result = SkillQuality.inspect("[guide](../guide.md)", at: alias.appendingPathComponent("SKILL.md"))
        XCTAssertEqual(result.checkedLocalReferences, 1)
        XCTAssertTrue(result.issues.isEmpty)
    }
    func testSecretShapedTargetsAreRedactedAndNoSourceTextIsRetained() throws {
        let result = inspect("[private label](references/sk-abcdefghijklmnopqrst.md)")
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(json.contains("abcdefghijklmnopqrst"))
        XCTAssertFalse(json.contains("private label"))
    }
    func testIdenticalIndependentFilesAreInfoButAliasesAreNotCopies() throws {
        let home = root!
        let first = home.appendingPathComponent(".agents/skills/one")
        let second = home.appendingPathComponent(".agents/skills/two")
        for url in [first, second] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try "---\nname: fixture\ndescription: fixture\n---\nbody".write(to: url.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".agents/skills/alias"), withDestinationURL: first)
        let report = AgentDoctor.context(DoctorEnvironment(home: home))
        XCTAssertEqual(report.skills.count, 3)
        XCTAssertTrue(report.skills.allSatisfy { $0.skillFootprint?.identicalContentFiles == 2 })
        XCTAssertEqual(report.findings.filter { $0.message.contains("Identical SKILL.md") }.count, 3)
        XCTAssertTrue(report.findings.filter { $0.message.contains("Identical SKILL.md") }.allSatisfy { $0.severity == .info })
    }
    func testCachedVersionProblemsAreEvidenceNotAnActiveHealthWarning() throws {
        let plugin = root.appendingPathComponent(".codex/plugins/cache/market/fixture/1")
        try FileManager.default.createDirectory(at: plugin.appendingPathComponent(".codex-plugin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plugin.appendingPathComponent("skills/fixture"), withIntermediateDirectories: true)
        try #"{"name":"fixture","skills":"./skills"}"#.write(to: plugin.appendingPathComponent(".codex-plugin/plugin.json"), atomically: true, encoding: .utf8)
        try "---\nname: fixture\ndescription: fixture\n---\n[missing](missing.md)".write(to: plugin.appendingPathComponent("skills/fixture/SKILL.md"), atomically: true, encoding: .utf8)
        let report = AgentDoctor.context(DoctorEnvironment(home: root))
        XCTAssertEqual(report.skills.first?.skillFootprint?.quality?.issues.count, 1)
        let evidence = report.findings.filter { $0.message.contains("does not exist now") }
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(evidence.first?.severity, .info)
    }
}
