import XCTest
import ThermoL10n
@testable import AgentDoctor

final class ContextFootprintTests: XCTestCase {
    var home: URL!
    var previousLanguage: Language?
    override func setUpWithError() throws {
        previousLanguage = L10n.override
        L10n.override = .english
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        L10n.override = previousLanguage
        try FileManager.default.removeItem(at: home)
    }

    func write(_ path: String, _ text: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func scan() -> ConfigChecks {
        var checks = ConfigChecks(env: DoctorEnvironment(home: home, path: [], run: { _, _ in
            XCTFail("Static inspection must not run commands")
            return nil
        }))
        checks.checkSkills()
        return checks
    }

    func testNestedCollectionsAndSystemSkillsAreInspectedIndividually() throws {
        try write(".agents/skills/bundle/deeper/one/SKILL.md", "---\nname: one\ndescription: test\n---\nbody")
        try write(".codex/skills/.system/two/SKILL.md", "---\nname: two\ndescription: test\n---\nlonger body")
        let checks = scan()
        XCTAssertEqual(checks.inventory.skills, 2)
        XCTAssertEqual(Set(checks.items.map(\.name)), ["one", "two"])
        XCTAssertTrue(checks.items.allSatisfy { $0.skillFootprint != nil })
        XCTAssertTrue(checks.items.allSatisfy { $0.actions.isEmpty }, "nested aliases must not offer to trash shared targets")
    }

    func testCatalogUsesWholeMultilineDescriptionButNotBody() throws {
        let text = "---\nname: sample\ndescription: >-\n  first line\n  second: more words\n---\n" + String(repeating: "body ", count: 100)
        try write(".agents/skills/sample/SKILL.md", text)
        let footprint = try XCTUnwrap(scan().items.first?.skillFootprint)
        XCTAssertEqual(footprint.catalog, TextFootprint("sample\nfirst line second: more words"))
        XCTAssertEqual(footprint.body.bytes, 500)
        XCTAssertEqual(footprint.document.bytes, text.utf8.count)
        XCTAssertGreaterThan(footprint.document.estimatedTokens, footprint.catalog.estimatedTokens)
    }

    func testLinkCycleIsExplicitAndIndependentAliasRemainsVisible() throws {
        try write(".agents/skills/real/SKILL.md", "---\nname: one\ndescription: x\n---")
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".agents/skills/alias"),
                                                 withDestinationURL: home.appendingPathComponent(".agents/skills/real"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".agents/skills/collection"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".agents/skills/collection/loop"),
                                                 withDestinationURL: home.appendingPathComponent(".agents/skills"))
        let checks = scan()
        XCTAssertEqual(checks.inventory.skills, 2)
        XCTAssertTrue(checks.findings.contains { $0.message.contains("incomplete") && $0.item == nil })
        XCTAssertFalse(checks.findings.contains { $0.message.contains("share this name") }, "same canonical target is not a conflict")
    }

    func testOversizedInvalidAndNonRegularFilesCannotLookInspected() throws {
        try write(".agents/skills/large/SKILL.md", String(repeating: "x", count: 1_048_577))
        try write(".agents/skills/invalid/SKILL.md", "")
        try Data([0xff, 0xfe, 0xff]).write(to: home.appendingPathComponent(".agents/skills/invalid/SKILL.md"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".agents/skills/directory/SKILL.md"), withIntermediateDirectories: true)
        let checks = scan()
        XCTAssertEqual(checks.inventory.skills, 0)
        XCTAssertEqual(checks.items.count, 3)
        XCTAssertTrue(checks.items.allSatisfy { $0.skillFootprint == nil })
        XCTAssertEqual(checks.findings.filter { $0.message.contains("1 MiB") }.count, 3)
    }

    func testNoSourceTextOrCredentialsAreStoredInFootprints() throws {
        let secret = "sk-abcdefghijklmnopqrst"
        try write(".agents/skills/secret/SKILL.md", "---\nname: secret\ndescription: test\n---\nAPI_TOKEN=" + secret)
        let footprint = try XCTUnwrap(scan().items.first?.skillFootprint)
        let json = String(decoding: try JSONEncoder().encode(footprint), as: UTF8.self)
        XCTAssertFalse(json.contains(secret))
        XCTAssertFalse(json.contains("API_TOKEN"))
        XCTAssertEqual(footprint.contentHash.count, 64)
    }

    func testMeasurementsSeparateExactCountsFromModelIndependentEstimate() {
        let value = TextFootprint("abcd中文\n")
        XCTAssertEqual(value.bytes, 11)
        XCTAssertEqual(value.characters, 7)
        XCTAssertEqual(value.lines, 2)
        XCTAssertEqual(value.estimatedTokens, 4)
        XCTAssertEqual(value.estimator, "ascii4-unicode1-v1")
        XCTAssertEqual(TextFootprint("").estimatedTokens, 0)
    }

    func testOldReportsDecodeWithoutFootprint() throws {
        let json = #"{"id":"x","area":"skills","agent":"codex","name":"x","detail":"x","enabled":true,"actions":[]}"#
        XCTAssertNil(try JSONDecoder().decode(AgentItem.self, from: Data(json.utf8)).skillFootprint)
    }

    func testContextRanksFilesWithoutInvokingServersAndKeepsMCPUnknown() throws {
        try write(".agents/skills/small/SKILL.md", "---\nname: small\ndescription: x\n---\nx")
        try write(".agents/skills/large/SKILL.md", "---\nname: large\ndescription: x\n---\n" + String(repeating: "x", count: 100))
        try write(".cursor/mcp.json", #"{"mcpServers":{"fixture":{"url":"https://example.invalid/mcp"}}}"#)
        let report = AgentDoctor.context(DoctorEnvironment(home: home, path: [], run: { _, _ in
            XCTFail("No process commands or MCP calls expected")
            return nil
        }))
        XCTAssertEqual(report.skills.map(\.name), ["large", "small"])
        XCTAssertEqual(report.mcpServers.count, 1)
        XCTAssertTrue(report.mcpNote.contains("have not been measured"))
        XCTAssertFalse(report.cancelled)
    }
}
