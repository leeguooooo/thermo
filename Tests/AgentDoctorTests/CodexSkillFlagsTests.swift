import XCTest
@testable import AgentDoctor

final class CodexSkillFlagsTests: XCTestCase {
    func testAbsoluteEntriesCommentsAndQuotedPaths() {
        let flags = ConfigChecks.codexSkillFlags("""
        [[skills.config]] # entry
        path = "/tmp/owned#skill/SKILL.md" # not part of path
        enabled = false # boolean
        [[skills.config]]
        enabled = true
        path = '/tmp/other/SKILL.md'
        [features]
        skills = true
        """)
        XCTAssertFalse(flags.incomplete)
        XCTAssertEqual(flags.paths[URL(fileURLWithPath: "/tmp/owned#skill/SKILL.md").resolvingSymlinksInPath().path], false)
        XCTAssertEqual(flags.paths[URL(fileURLWithPath: "/tmp/other/SKILL.md").resolvingSymlinksInPath().path], true)
    }

    func testUnsupportedAndConflictingEntriesNeverHideFiles() {
        let valid = "[[skills.config]]\npath = \"/tmp/owned/SKILL.md\"\nenabled = false\n"
        for invalid in ["[[skills.config]]\npath = \"relative/SKILL.md\"\nenabled = false",
                        "[[skills.config]]\npath = \"/tmp/owned/SKILL.md\"\nenabled = \"false\"",
                        "[[skills.config]]\npath = \"/tmp/owned/SKILL.md\"",
                        "[[skills.config]]\npath = \"/tmp/owned/SKILL.md\"\nenabled = true",
                        "[skills]\nconfig = []", "[[skills.\"config\"]]\npath = '/tmp/other/SKILL.md'\nenabled = false",
                        "[['skills'.'config']]\npath = '/tmp/owned/SKILL.md'\nenabled = true",
                        "[[skills.config]]\npath = \"\\/tmp/owned/SKILL.md\"\nenabled = false"] {
            let flags = ConfigChecks.codexSkillFlags(valid + invalid)
            XCTAssertTrue(flags.incomplete, invalid); XCTAssertTrue(flags.paths.isEmpty)
        }
    }

    func testDisabledCopyStaysInInventoryWithoutActiveNameCollision() throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let text = "---\nname: owned\ndescription: owned fixture\n---\nbody"
        for parent in [".agents/skills/owned", ".codex/skills/owned"] {
            let folder = home.appendingPathComponent(parent)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        let disabled = home.appendingPathComponent(".codex/skills/owned/SKILL.md").path
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let quoted = String(decoding: try encoder.encode(disabled), as: UTF8.self)
        try "[[skills.config]]\npath = \(quoted)\nenabled = false\n".write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        let result = AgentDoctor.context(DoctorEnvironment(home: home))
        XCTAssertEqual(result.skills.count, 2)
        XCTAssertEqual(result.skills.filter { !$0.enabled }.count, 1)
        XCTAssertEqual(result.skills.filter { $0.skillFootprint?.codexConfiguredEnabled == false }.count, 1)
        XCTAssertEqual(result.summaries.first?.uniqueFiles, 2)
        XCTAssertEqual(result.summaries.first?.documentBytes, 2 * text.utf8.count)
        XCTAssertFalse(result.findings.contains { $0.message.contains("share this name") })
        var footprint = try XCTUnwrap(result.skills.first { !$0.enabled }?.skillFootprint)
        footprint.codexConfiguredEnabled = nil
        let encoded = try JSONEncoder().encode(footprint)
        XCTAssertNil(try JSONDecoder().decode(SkillFootprint.self, from: encoded).codexConfiguredEnabled)
    }

    func testDisabledAliasResolvesToTheCanonicalSkill() throws {
        let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let file = target.appendingPathComponent("SKILL.md")
        try "fixture".write(to: file, atomically: true, encoding: .utf8)
        let alias = home.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let path = String(decoding: try encoder.encode(alias.appendingPathComponent("SKILL.md").path), as: UTF8.self)
        let flags = ConfigChecks.codexSkillFlags("[[skills.config]]\npath = \(path)\nenabled = false")
        XCTAssertFalse(flags.incomplete); XCTAssertEqual(flags.paths, [file.path: false])
    }
}
