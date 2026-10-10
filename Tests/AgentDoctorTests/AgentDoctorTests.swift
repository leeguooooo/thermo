@testable import AgentDoctor
import XCTest

final class ShellTests: XCTestCase {
    func testProgramsSkipsAssignmentsBuiltinsAndRedirects() {
        XCTAssertEqual(Shell.programs("FOO='a b' /opt/x/tool run 2>/dev/null || true"), ["/opt/x/tool"])
        XCTAssertEqual(Shell.programs("jq -c '.x' | grep y"), ["jq", "grep"])
        XCTAssertEqual(Shell.programs("/bin/sh -c '[ -x \"$HOME/b\" ] && \"$HOME/b\" --source claude; exit 0'"), ["$HOME/b"])
    }

    func testCommandSubstitutionIsOneWord() {
        let cmd = #"[ -f a ] && [ "$(node -p "JSON.parse(require('fs').readFileSync('m.json','utf8')).x")" != "$(git rev-parse HEAD 2>/dev/null)" ] && echo hi || true"#
        XCTAssertEqual(Shell.programs(cmd), [])
    }

    func testGuarded() {
        XCTAssertTrue(Shell.isGuarded("[ -x \"$X\" ] && \"$X\" || true"))
        XCTAssertFalse(Shell.isGuarded("/usr/local/bin/missing --flag"))
    }
}

final class RedactTests: XCTestCase {
    func testRedactsCommonShapes() {
        let s = Redact.text("x --token cgu-194600eeecd0b804 DISCORD_TOKEN=MTUxMzc4MTE3NDE1 Bearer abcdefghijkl sk-ant-abcdefghijklmnop")
        XCTAssertFalse(s.contains("194600eeecd0"))
        XCTAssertFalse(s.contains("Mzc4MTE3"))
        XCTAssertFalse(s.contains("efghijkl"))
        XCTAssertFalse(s.contains("abcdefghijklmnop"))
        XCTAssertTrue(s.contains("--token cgu-••••"))
    }

    func testRedactionKeepsPunctuation() {
        XCTAssertEqual(Redact.text("(env API_TOKEN=abcd••••); next"), "(env API_TOKEN=abcd••••); next")
    }

    func testLiteralSecret() {
        XCTAssertTrue(Redact.isLiteralSecret("abcdefghijk"))
        XCTAssertFalse(Redact.isLiteralSecret("${GITHUB_TOKEN}"))
        XCTAssertFalse(Redact.isLiteralSecret("/path/to/key"))
    }
}

final class ParserTests: XCTestCase {
    func testTomlServers() {
        let toml = """
        [model]
        name = "x"
        [mcp_servers.codegraph]
        command = "codegraph"
        args = ["serve", "--mcp"]
        [mcp_servers.discord.env]
        DISCORD_TOKEN = "secretsecret"
        [mcp_servers."quoted.name"]
        url = "https://example.com/mcp"
        enabled = false
        """
        let s = ConfigChecks.tomlServers(toml, source: "t")
        XCTAssertEqual(s.map(\.name), ["codegraph", "discord", "quoted.name"])
        XCTAssertEqual(s[0].args, ["serve", "--mcp"])
        XCTAssertEqual(s[1].env["DISCORD_TOKEN"], "secretsecret")
        XCTAssertTrue(s[2].disabled)
    }

    func testLaunchctlState() {
        let text = "gui/501/x = {\n\tactive count = 0\n\tstate = not running\n\truns = 71880\n\tlast exit code = 127\n\tendpoints = {\n\t\tstate = active\n\t}\n}\n"
        XCTAssertEqual(Launchd.state(text), LaunchState(state: "not running", runs: 71880, lastExit: "127", pid: nil))
    }

    func testServicePids() {
        let text = "gui/501 = {\n\tservices = {\n\t\t   93012      - \tcom.a\n\t\t       0      1 \tcom.b\n\t}\n}\n"
        XCTAssertEqual(Launchd.servicePids(text), [93012: "com.a"])
    }

    func testPsParseAndElapsed() {
        let rows = Processes.parse("  12     1   0.5  2048 1-02:03:04 /usr/bin/node /x/server.mjs --a b\n")
        XCTAssertEqual(rows.first?.pid, 12)
        XCTAssertEqual(rows.first?.elapsed, TimeInterval(93784))
        XCTAssertEqual(rows.first?.args, "/usr/bin/node /x/server.mjs --a b")
    }

    func testGroupNames() {
        XCTAssertEqual(Processes.groupName("/Users/x/.local/bin/claude --session-id 1", executable: "/Users/x/.local/share/claude/versions/2.1.295"), "claude")
        XCTAssertEqual(Processes.groupName("node /a/b/dist/bin/codegraph.js serve", executable: "/usr/bin/node"), "node dist/bin/codegraph.js")
        XCTAssertEqual(Processes.groupName("/x/discord-use mcp", executable: "/x/discord-use"), "discord-use mcp")
    }
}

/// End-to-end against a fixture home with fake ps/launchctl.
final class DoctorTests: XCTestCase {
    var home: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("agentdoctor-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: home) }

    func write(_ path: String, _ text: String) throws {
        let u = home.appendingPathComponent(path)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }

    func diagnose(ps: String = "", launchctl: [String: String] = [:], exe: [Int32: String] = [:]) -> DoctorReport {
        let env = DoctorEnvironment(home: home, uid: 501, path: ["/bin", "/usr/bin"], run: { tool, args in
            if tool == "/bin/ps" { return ps }
            if tool == "/bin/launchctl" { return launchctl[args.last ?? ""] }
            return nil
        }, executablePath: { exe[$0] })
        return AgentDoctor.run(env)
    }

    func find(_ r: DoctorReport, _ area: Area, _ subject: String) -> [Finding] {
        r.findings.filter { $0.area == area && $0.subject.hasPrefix(subject) }
    }

    func testEmptyHomeHasNoFindings() {
        let r = diagnose()
        XCTAssertEqual(r.findings, [])
        XCTAssertEqual(r.inventory.agents, [])
    }

    func testHooks() throws {
        try write(".claude/settings.json", """
        {"hooks": {
          "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/nope/tool hook"}]}],
          "Stop": [{"hooks": [{"type": "command", "command": "[ -x /nope/x ] && /nope/x || true", "timeout": 86400}]}],
          "SessionEnd": [{"hooks": [{"type": "command", "command": "echo ok 2>/dev/null"}]}]
        }, "statusLine": {"type": "command", "command": "/nope/cs render", "refreshInterval": 1}}
        """)
        try write(".gemini/settings.json", #"{"hooks": {"AfterTool": [{"hooks": [{"command": "true", "timeout": 60000}]}]}}"#)
        let r = diagnose()
        XCTAssertEqual(find(r, .hooks, "PreToolUse").first?.severity, .error)
        let stop = find(r, .hooks, "Stop")
        XCTAssertEqual(stop.map(\.severity).sorted(), [.info, .info])  // guarded no-op + long timeout
        XCTAssertTrue(find(r, .hooks, "SessionEnd").isEmpty)
        XCTAssertTrue(find(r, .hooks, "AfterTool").isEmpty, "gemini timeouts are milliseconds")
        XCTAssertEqual(find(r, .statusline, "statusLine").map(\.severity).sorted(), [.error, .info])
        XCTAssertEqual(r.inventory.hooks, 4)
    }

    func testMCPServers() throws {
        try write(".claude.json", """
        {"mcpServers": {
           "ok": {"command": "/bin/sh"},
           "gone": {"command": "/nope/server"},
           "leaky": {"command": "/bin/sh", "env": {"API_TOKEN": "abcdefghijklmnop"}},
           "remote": {"type": "http", "url": "https://x"}
         },
         "projects": {"/nope/project": {"mcpServers": {"p": {"command": "/nope/p"}}}}}
        """)
        let r = diagnose()
        XCTAssertTrue(find(r, .mcp, "ok").isEmpty)
        XCTAssertTrue(find(r, .mcp, "remote").isEmpty)
        XCTAssertEqual(find(r, .mcp, "gone").first?.severity, .error)
        let leak = try XCTUnwrap(find(r, .mcp, "leaky").first)
        XCTAssertEqual(leak.severity, .warning)
        XCTAssertFalse(leak.message.contains("efghijklmnop"))
        XCTAssertEqual(find(r, .mcp, "p (").first?.severity, .info, "dead project reported once, not as a missing command")
        XCTAssertEqual(find(r, .mcp, "p (").count, 1)
    }

    func testPlugins() throws {
        let installed = home.appendingPathComponent("plugins/a").path
        try write("plugins/a/.claude-plugin/plugin.json", "{")
        try write("plugins/a/hooks/hooks.json", #"{"hooks": {"Stop": [{"hooks": [{"command": "${CLAUDE_PLUGIN_ROOT}/missing.sh"}]}]}}"#)
        try write(".claude/plugins/installed_plugins.json", """
        {"version": 2, "plugins": {
          "a@m": [{"scope": "user", "installPath": "\(installed)"}],
          "gone@m": [{"scope": "user", "installPath": "/nope/gone"}],
          "proj@m": [{"scope": "project", "projectPath": "/nope/proj", "installPath": "\(installed)"}]
        }}
        """)
        try write(".claude/plugins/known_marketplaces.json", #"{"m": {}}"#)
        try write(".claude/settings.json", #"{"enabledPlugins": {"a@m": true, "gone@m": true, "ghost@other": true}}"#)
        let r = diagnose()
        XCTAssertEqual(find(r, .plugins, "a@m").first?.message, "plugin.json is not valid JSON")
        XCTAssertEqual(find(r, .hooks, "Stop").first?.severity, .error, "plugin hook path expanded via CLAUDE_PLUGIN_ROOT")
        XCTAssertTrue(find(r, .hooks, "Stop").first?.message.contains("missing.sh") ?? false)
        XCTAssertEqual(find(r, .plugins, "gone@m").first?.severity, .error)
        XCTAssertEqual(find(r, .plugins, "proj@m").first?.severity, .info)
        XCTAssertEqual(find(r, .plugins, "ghost@other").map(\.severity), [.warning, .warning])  // not installed + unknown marketplace
    }

    func testSkills() throws {
        try write(".claude/skills/good/SKILL.md", "---\nname: good\ndescription: does things\n---\nbody")
        try write(".claude/skills/nodesc/SKILL.md", "no front matter")
        try fm.createDirectory(at: home.appendingPathComponent(".claude/skills/empty"), withIntermediateDirectories: true)
        try write(".claude/skills/collection/abc/inner/SKILL.md", "---\nname: inner\ndescription: x\n---")
        try fm.createSymbolicLink(atPath: home.appendingPathComponent(".claude/skills/broken").path, withDestinationPath: "/nope/skill")
        try write(".agents/skills/good/SKILL.md", "---\nname: good\ndescription: other copy\n---")
        try write(".codex/skills/good/SKILL.md", "---\nname: good\ndescription: codex copy\n---")
        let r = diagnose()
        XCTAssertTrue(find(r, .skills, "good").allSatisfy { $0.agent == "codex" }, "Claude Code does not read ~/.agents/skills")
        XCTAssertEqual(find(r, .skills, "good").count, 1)
        XCTAssertEqual(find(r, .skills, "nodesc").first?.severity, .warning)
        XCTAssertEqual(find(r, .skills, "empty").first?.severity, .warning)
        XCTAssertTrue(find(r, .skills, "collection").isEmpty)
        XCTAssertTrue(find(r, .skills, "broken").first?.message.contains("broken symlink") ?? false)
    }

    func plist(_ label: String, _ args: [String], keepAlive: Any = true, log: String? = nil) throws {
        var d: [String: Any] = ["Label": label, "ProgramArguments": args, "KeepAlive": keepAlive]
        if let log { d["StandardErrorPath"] = log }
        let data = try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
        let u = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
    }

    func testLaunchAgents() throws {
        try plist("loop", ["/bin/sh", "-c", "exit 3"])
        try plist("script", ["/bin/bash", "-lc", "$HOME/gone.sh"])
        let log = home.appendingPathComponent("hud.log").path
        try String(repeating: "[hud] already running, exiting\n", count: 500).write(toFile: log, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86400 * 10)], ofItemAtPath: log)
        try plist("hud", ["/bin/sh", "hud"], log: log)
        try plist("fine", ["/bin/sh"], keepAlive: ["SuccessfulExit": false])
        let r = diagnose(launchctl: [
            "gui/501/loop": "x = {\n\tstate = not running\n\truns = 900\n\tlast exit code = 3\n}",
            "gui/501/hud": "x = {\n\tstate = running\n\truns = 1\n\tpid = 5\n}",
            "gui/501/fine": "x = {\n\tstate = running\n\truns = 2\n}",
        ])
        XCTAssertEqual(find(r, .launchd, "loop").first?.severity, .error)
        XCTAssertTrue(find(r, .launchd, "script").first?.message.contains("gone.sh") ?? false)
        let hud = try XCTUnwrap(find(r, .launchd, "hud").first)
        XCTAssertEqual(hud.severity, .info, "a past loop is a note, not an active problem")
        XCTAssertTrue(hud.message.contains("100%"))
        XCTAssertTrue(find(r, .launchd, "fine").isEmpty)
        XCTAssertEqual(r.inventory.launchAgents, 4)
    }

    func testProcesses() throws {
        for bin in ["node", "stuck-mcp", "claude", "claude-statusbar/cs-python"] { try write("bin/" + bin, "") }
        let b = home.appendingPathComponent("bin").path
        let ps = """
          10     1   0.0  1024 2-00:00:00 /nope/node /a/codex/scripts/broker.mjs serve
          11     1   0.0  1024 2-00:00:00 \(b)/node /a/codex/scripts/broker.mjs serve
          12     1   0.0  1024 2-00:00:00 \(b)/node /a/codex/scripts/broker.mjs serve
          13     1   0.0  1024    01:00 \(b)/claude-statusbar/cs-python hud start
          14   500  95.0  1024    01:00 \(b)/stuck-mcp serve
          20   300   1.0  1024    01:00 \(b)/claude --session-id a
        """
        let r = diagnose(ps: ps, launchctl: ["gui/501": "s = {\n\tservices = {\n\t\t 13 - \tcom.hud\n\t}\n}"],
                         exe: [11: b + "/node", 12: b + "/node", 13: b + "/claude-statusbar/cs-python", 14: b + "/stuck-mcp", 20: b + "/claude"])
        XCTAssertEqual(r.sessions, 1)
        let broker = find(r, .processes, "node codex/scripts/broker.mjs")
        XCTAssertTrue(broker.contains { $0.message.contains("deleted") && $0.fix == "kill 10" })
        XCTAssertTrue(broker.contains { $0.message.contains("2 detached") })
        XCTAssertTrue(find(r, .processes, "cs-python").isEmpty, "launchd-owned pid is not an orphan")
        XCTAssertEqual(find(r, .processes, "stuck-mcp").first?.severity, .warning)
        XCTAssertEqual(r.findings.count, 3)
    }
}
