import XCTest
@testable import AgentDoctor

final class ExtensionTests: XCTestCase {
    var home: URL!
    let now = Date(timeIntervalSince1970: 1_792_400_000)

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ext-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    func write(_ rel: String, _ text: String) throws {
        let url = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func executable(_ name: String) throws {
        try write("bin/" + name, "#!/bin/sh\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appendingPathComponent("bin/" + name).path)
    }

    func ms(daysAgo: Double) -> Int { Int((now.timeIntervalSince1970 - daysAgo * 86400) * 1000) }

    func testVersions() {
        XCTAssertEqual(ConfigChecks.newer("1.2.10", than: "1.2.9"), true)
        XCTAssertEqual(ConfigChecks.newer("1.3", than: "1.3.0"), false)
        XCTAssertEqual(ConfigChecks.newer("1.2.0", than: "1.10.0"), false, "a newer install is not downgraded")
        XCTAssertNil(ConfigChecks.newer("abc1234", than: "1.0.0"))
    }

    func testPluginUpdateFromCatalogAndUnusedOnlyWhenCalledBefore() throws {
        let market = ".claude/plugins/marketplaces/m"
        try write(market + "/.claude-plugin/marketplace.json",
                  #"{"plugins":[{"name":"tool","version":"2.1.0","source":{"source":"github"}},{"name":"bar","source":"./plugins/bar"},{"name":"quiet","version":"1.0.0"}]}"#)
        try write(market + "/plugins/bar/.claude-plugin/plugin.json", #"{"version":"0.9.0"}"#)
        try write(".claude/plugins/installed_plugins.json", """
            {"version":2,"plugins":{
              "tool@m":[{"scope":"user","installPath":"/x/tool","version":"2.0.3"}],
              "bar@m":[{"scope":"user","installPath":"/x/bar","version":"0.9.0"}],
              "quiet@m":[{"scope":"user","installPath":"/x/quiet","version":"1.0.0"}]}}
            """)
        try write(".claude.json", """
            {"pluginUsage":{"tool@m":{"usageCount":5,"lastUsedAt":\(ms(daysAgo: 90))},"quiet@m":{"usageCount":0,"lastUsedAt":\(ms(daysAgo: 200))}}}
            """)
        try executable("claude")
        var c = ConfigChecks(env: DoctorEnvironment(home: home, path: [home.appendingPathComponent("bin").path], run: { _, _ in nil }, now: now))
        for id in ["tool@m", "bar@m", "quiet@m"] { c.item(.plugins, agent: "claude", id: id + "|", name: id, detail: "", source: nil) }
        c.currentItem = nil
        c.checkExtensions()

        let tool = try XCTUnwrap(c.items.first { $0.name == "tool@m" })
        XCTAssertEqual(tool.update, ExtensionUpdate(installed: "2.0.3", available: "2.1.0"))
        let update = try XCTUnwrap(tool.actions.first { $0.kind == .update })
        XCTAssertFalse(update.bulk)
        XCTAssertEqual(update.steps, [.run(tool: home.appendingPathComponent("bin/claude").path, args: ["plugin", "update", "tool@m", "-s", "user"], cwd: nil)])
        XCTAssertNil(c.items.first { $0.name == "bar@m" }?.update, "same version in the plugin's own manifest")
        let unused = c.findings.filter { $0.message.contains("not used") }.map(\.subject)
        XCTAssertEqual(unused, ["tool@m"], "a plugin never called (status line, LSP) is not judged")
    }

    func testLockedSkillsUpdateFromCacheAndUninstallThroughTheTool() throws {
        try write(".agents/.skill-lock.json", """
            {"version":3,"skills":{
              "fresh":{"source":"o/r","sourceType":"github","skillPath":"skills/fresh/SKILL.md","skillFolderHash":"aaaa111","installedAt":"2026-01-01T00:00:00.000Z"},
              "stale":{"source":"o/r","sourceType":"github","skillPath":"SKILL.md","skillFolderHash":"bbbb222","installedAt":"2026-01-01T00:00:00.000Z"}}}
            """)
        try write(".claude.json", #"{"skillUsage":{"fresh":{"usageCount":3,"lastUsedAt":\#(ms(daysAgo: 2))}}}"#)
        SkillUpdateCache(checked: now, latest: ["fresh": "aaaa111", "stale": "cccc333"]).save(home: home)
        try executable("npx")
        var c = ConfigChecks(env: DoctorEnvironment(home: home, path: [home.appendingPathComponent("bin").path], run: { _, _ in nil }, now: now))
        for name in ["fresh", "stale"] { c.item(.skills, agent: "claude", id: name, name: name, detail: "", source: nil) }
        c.currentItem = nil
        c.checkExtensions()

        let stale = try XCTUnwrap(c.items.first { $0.name == "stale" })
        XCTAssertEqual(stale.update, ExtensionUpdate(installed: "bbbb222", available: "cccc333"))
        XCTAssertEqual(stale.actions.first?.kind, .uninstall)
        XCTAssertEqual(stale.actions.first?.steps.first, .run(tool: home.appendingPathComponent("bin/npx").path, args: ["-y", "skills", "remove", "stale", "-g", "-y"], cwd: home.path))
        XCTAssertNil(c.items.first { $0.name == "fresh" }?.update)
        XCTAssertEqual(c.findings.filter { $0.message.contains("never used") }.map(\.subject), ["stale"])
    }

    func testCodexPluginsAreListedWithTheirState() throws {
        try write(".codex/config.toml", """
            model = "x"
            [plugins."github@openai-curated"]
            enabled = true

            [plugins."pdf@runtime"]
            enabled = false
            [projects."/tmp/p"]
            trust_level = "trusted"
            """)
        var c = ConfigChecks(env: DoctorEnvironment(home: home, path: [], run: { _, _ in nil }, now: now))
        c.checkExtensions()
        let codex = c.items.filter { $0.agent == "codex" && $0.area == .plugins }
        XCTAssertEqual(codex.map(\.name), ["github@openai-curated", "pdf@runtime"])
        XCTAssertEqual(codex.map(\.enabled), [true, false])
    }
}
