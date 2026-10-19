import XCTest
import ThermoL10n
@testable import AgentDoctor

final class SkillDiscoveryTests: XCTestCase {
    var home: URL!
    var language: Language?
    override func setUpWithError() throws {
        language = L10n.override; L10n.override = .english
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        L10n.override = language
        try FileManager.default.removeItem(at: home)
    }
    func write(_ path: String, _ text: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    let document = "---\nname: fixture\ndescription: a test skill\n---\nbody"
    func scan(project: String? = nil) -> ContextInventory {
        AgentDoctor.context(DoctorEnvironment(home: home, project: project.map { home.appendingPathComponent($0) }, path: [], run: { _, _ in
            XCTFail("Static scan must not execute a CLI"); return nil
        }))
    }
    func testAliasesAndHardLinksDoNotInflateHostDocumentTotals() throws {
        try write(".agents/skills/one/SKILL.md", document)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".agents/skills/alias"), withDestinationURL: home.appendingPathComponent(".agents/skills/one"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/skills/hard"), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: home.appendingPathComponent(".agents/skills/one/SKILL.md"), to: home.appendingPathComponent(".codex/skills/hard/SKILL.md"))
        let result = scan()
        let summary = try XCTUnwrap(result.summaries.first { $0.host == "codex" })
        XCTAssertEqual(summary.measuredEntries, 3)
        XCTAssertEqual(summary.uniqueFiles, 1)
        XCTAssertEqual(summary.aliases, 2)
        XCTAssertEqual(summary.catalogEntries, 1)
        XCTAssertEqual(summary.documentBytes, document.utf8.count)
        XCTAssertFalse(result.findings.contains { $0.message.contains("share this name") })
    }
    func testIdenticalContentsInDifferentFilesAreNotMerged() throws {
        try write(".agents/skills/one/SKILL.md", document)
        try write(".agents/skills/two/SKILL.md", document)
        let summary = try XCTUnwrap(scan().summaries.first)
        XCTAssertEqual(summary.uniqueFiles, 2)
        XCTAssertEqual(summary.documentBytes, 2 * document.utf8.count)
        XCTAssertEqual(summary.aliases, 0)
    }
    func testExplicitProjectAscendsToGitRootButNotBeyondIt() throws {
        try write("repo/.git", "gitdir: fixture")
        try write("repo/.agents/skills/root/SKILL.md", document)
        try write("repo/sub/.agents/skills/local/SKILL.md", document.replacingOccurrences(of: "fixture", with: "local"))
        try write(".agents/skills/user/SKILL.md", document)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("repo/sub/deeper"), withIntermediateDirectories: true)
        XCTAssertEqual(scan().skills.count, 1)
        let result = scan(project: "repo/sub/deeper")
        XCTAssertEqual(result.skills.count, 3)
        XCTAssertEqual(result.skills.filter { $0.skillFootprint?.scope == "project" }.count, 2)
        XCTAssertTrue(result.skills.filter { $0.skillFootprint?.scope == "project" }.allSatisfy { $0.actions.isEmpty })
    }
    func testProjectOutsideRepositoryDoesNotScanParentProjects() throws {
        try write("folder/.agents/skills/one/SKILL.md", document)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("folder/child"), withIntermediateDirectories: true)
        XCTAssertEqual(scan(project: "folder/child").skills.count, 0)
        XCTAssertEqual(scan(project: "folder").skills.count, 1)
    }
    func testCacheVersionsAndEnablementRemainSeparateFromDirectoryTotals() throws {
        try write(".codex/config.toml", "[plugins.\"fixture@market\"]\nenabled = false\n")
        for version in ["1", "2"] {
            try write(".codex/plugins/cache/market/fixture/\(version)/.codex-plugin/plugin.json", #"{"name":"fixture","skills":"./skills"}"#)
            try write(".codex/plugins/cache/market/fixture/\(version)/skills/one/SKILL.md", document)
        }
        let result = scan()
        XCTAssertEqual(result.skills.count, 2)
        XCTAssertTrue(result.skills.allSatisfy { !$0.enabled && $0.actions.isEmpty && $0.skillFootprint?.pluginConfiguredEnabled == false })
        let summary = try XCTUnwrap(result.summaries.first)
        XCTAssertEqual(summary.uniqueFiles, 0)
        XCTAssertEqual(summary.documentBytes, 0)
        XCTAssertEqual(summary.cacheUniqueFiles, 2)
        XCTAssertEqual(summary.cacheDocumentBytes, 2 * document.utf8.count)
    }
    func testCachePathTraversalIsNotFollowed() throws {
        try write(".codex/plugins/cache/market/fixture/1/.codex-plugin/plugin.json", #"{"name":"fixture","skills":"../../../../../../outside"}"#)
        try write("outside/one/SKILL.md", document)
        let result = scan()
        XCTAssertTrue(result.skills.isEmpty)
        XCTAssertTrue(result.findings.contains { $0.message.contains("cache inspection is incomplete") })
    }
    func testRootDeclaredCacheSkillIsInventoriedOnceAndCannotOfferRemoval() throws {
        let base = ".codex/plugins/cache/market/fixture/1"
        try write(".codex/config.toml", "[plugins.\"fixture@market\"]\nenabled = true\n")
        try write(base + "/.codex-plugin/plugin.json", #"{"name":"fixture","skills":["./","."]}"#)
        try write(base + "/SKILL.md", document)
        try write(base + "/references/example/SKILL.md", document.replacingOccurrences(of: "fixture", with: "not-independent"))
        let result = scan(), item = try XCTUnwrap(result.skills.first)
        XCTAssertEqual(result.skills.count, 1)
        XCTAssertEqual(item.name, "fixture")
        XCTAssertEqual(item.skillFootprint?.namespace, "fixture@market")
        XCTAssertEqual(item.skillFootprint?.pluginConfiguredEnabled, true)
        XCTAssertTrue(item.actions.isEmpty)
        XCTAssertEqual(result.summaries.first?.cacheUniqueFiles, 1)
        XCTAssertEqual(result.summaries.first?.uniqueFiles, 0)
        XCTAssertFalse(result.findings.contains { $0.message.contains("cache inspection is incomplete") })
    }
    func testEmptyAbsoluteAndEscapingSymlinkDeclarationsStillFailClosed() throws {
        let base = ".codex/plugins/cache/market/fixture/1"
        try write(base + "/.codex-plugin/plugin.json", #"{"skills":["","/","./escape"]}"#)
        try write("outside/SKILL.md", document)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(base + "/escape"), withDestinationURL: home.appendingPathComponent("outside"))
        let result = scan()
        XCTAssertTrue(result.skills.isEmpty)
        XCTAssertTrue(result.findings.contains { $0.message.contains("cache inspection is incomplete") })
    }
    func testInvalidRootSkillUsesManifestOwnerInsteadOfVersionWithoutInventingCatalogCounts() throws {
        let base = ".codex/plugins/cache/market/owner/0.4.1"
        try write(base + "/.codex-plugin/plugin.json", #"{"name":"declared-owner","skills":["./"]}"#)
        try write(base + "/SKILL.md", "---\nname: ignored-invalid-header\ndescription: Tool: run\n---\nbody")
        let report = scan(), item = try XCTUnwrap(report.skills.first), fp = try XCTUnwrap(item.skillFootprint)
        XCTAssertEqual(item.name, "declared-owner")
        XCTAssertEqual(fp.nameSource, "plugin_manifest")
        XCTAssertEqual(fp.namespace, "owner@market")
        XCTAssertEqual(fp.catalog.measurementComplete, false)
        XCTAssertNil(fp.catalog.comparisonTokens)
        XCTAssertEqual(fp.quality?.issues.first?.code, "invalid_front_matter")
        XCTAssertTrue(item.actions.isEmpty)
        XCTAssertTrue(report.findings.filter { $0.item == item.id }.allSatisfy { $0.subject == "declared-owner" })
    }
    func testManifestLabelNeverOverridesValidHeaderOrNamesChildSkills() throws {
        let base = ".codex/plugins/cache/market/owner/1"
        try write(base + "/.codex-plugin/plugin.json", #"{"name":"declared-owner","skills":["./"]}"#)
        try write(base + "/SKILL.md", document)
        var item = try XCTUnwrap(scan().skills.first)
        XCTAssertEqual(item.name, "fixture"); XCTAssertEqual(item.skillFootprint?.nameSource, "front_matter")
        try FileManager.default.removeItem(at: home.appendingPathComponent(base + "/SKILL.md"))
        try write(base + "/.codex-plugin/plugin.json", #"{"name":"declared-owner","skills":["./skills/child"]}"#)
        try write(base + "/skills/child/SKILL.md", "---\nname: ignored\ndescription: Tool: run\n---\nbody")
        item = try XCTUnwrap(scan().skills.first)
        XCTAssertEqual(item.name, "child"); XCTAssertEqual(item.skillFootprint?.nameSource, "directory")
        XCTAssertEqual(item.skillFootprint?.catalog.measurementComplete, false)
    }
    func testMissingOrUnsafeManifestNamesRemainExplicitDirectoryFallbacks() throws {
        let base = ".codex/plugins/cache/market/owner/0.4.1"
        for name in ["", "has\nnewline", "private/path", "trailing\n"] {
            let data = try JSONSerialization.data(withJSONObject: ["name": name, "skills": "./"])
            try write(base + "/.codex-plugin/plugin.json", String(decoding:data, as:UTF8.self))
            try write(base + "/SKILL.md", "---\nname: ignored\ndescription: Tool: run\n---\nbody")
            let item = try XCTUnwrap(scan().skills.first)
            XCTAssertEqual(item.name, "0.4.1"); XCTAssertEqual(item.skillFootprint?.nameSource, "directory")
            XCTAssertEqual(item.skillFootprint?.catalog.measurementComplete, false)
        }
    }
    func testSummaryIsEncodedAndOldFootprintsWithUnknownIdentityAreNotInventedAsUnique() throws {
        try write(".agents/skills/one/SKILL.md", document)
        let result = scan()
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any]
        XCTAssertNotNil(object["summaries"])
        var items = result.skills
        items[0].skillFootprint?.canonicalID = nil
        let summary = try XCTUnwrap(SkillContextSummary.summarize(items).first)
        XCTAssertEqual(summary.uniqueFiles, 0)
        XCTAssertEqual(summary.unverifiedIdentityEntries, 1)
    }
    func testBrokenProjectAndCacheLinksHaveNoRemovalActions() throws {
        try write("repo/.git", "gitdir: fixture")
        try write("repo/.agents/skills/one/SKILL.md", document)
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent("repo/.agents/skills/broken").path, withDestinationPath: "/missing-fixture")
        let base = ".codex/plugins/cache/market/fixture/1"
        try write(base + "/.codex-plugin/plugin.json", #"{"name":"fixture","skills":"./skills"}"#)
        try write(base + "/skills/one/SKILL.md", document)
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent(base + "/skills/broken").path, withDestinationPath: "/missing-fixture")
        let report = scan(project: "repo")
        let broken = report.skills.filter { $0.name == "broken" }
        XCTAssertEqual(broken.count, 2)
        XCTAssertTrue(broken.allSatisfy { $0.actions.isEmpty })
        XCTAssertEqual(report.summaries.first?.cacheEntries, 2)
        XCTAssertEqual(report.summaries.first?.cacheUniqueFiles, 1)
    }
}
