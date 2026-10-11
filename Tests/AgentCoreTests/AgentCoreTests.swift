import XCTest
@testable import AgentCore

final class AgentCoreTests: XCTestCase {
    var home = ""

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentcore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        home = dir.resolvingSymlinksInPath().path
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: home) }

    func write(_ rel: String, _ text: String) throws {
        let p = home + "/" + rel
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: p, atomically: false, encoding: .utf8)
    }

    // MARK: processes

    func testCurrentProcessIsReadCompletely() throws {
        let me = getpid()
        let table = ProcessTable.current()
        let row = try XCTUnwrap(table.entries.first { $0.pid == me })
        XCTAssertEqual(row.ppid, getppid())
        XCTAssertEqual(row.uid, getuid())
        XCTAssertEqual(row.executable, ProcessTable.pidPath(me))
        XCTAssertNotNil(row.executable)
        XCTAssertFalse(row.executableFromArgv)
        XCTAssertEqual(row.argv, ProcessInfo.processInfo.arguments)
        XCTAssertEqual(row.cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path)
        XCTAssertGreaterThan(row.rssKB, 1000)
        XCTAssertGreaterThan(row.elapsed, 0)
        XCTAssertLessThan(row.elapsed, 3600)
        XCTAssertGreaterThanOrEqual(row.cpu, 0)
        XCTAssertTrue(table.entries.allSatisfy { $0.uid == getuid() }, "default lists only this user")
    }

    func testRunningAndAgentDirectories() {
        let t = ProcessTable(entries: [
            AgentProcess(pid: 10, name: "Google Chrome", executable: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            AgentProcess(pid: 11, name: "2.1.296", executable: home + "/.local/share/claude/versions/2.1.296",
                         argv: ["claude", "--resume"], cwd: "/Users/x/src/app"),
            AgentProcess(pid: 12, name: "node", executable: "/opt/homebrew/bin/node", argv: ["node", "server.js"], cwd: "/Users/x/web"),
        ])
        XCTAssertEqual(t.running(["Google Chrome"]), "Google Chrome")
        XCTAssertNil(t.running(["Safari"]))
        XCTAssertEqual(t.agentDirectories(), ["/Users/x/src/app"])
    }

    func testCLINamesAndBundledHelpersDoNotCountAsTheApp() {
        let t = ProcessTable(entries: [
            AgentProcess(pid: 20, name: "claude", executable: home + "/.local/bin/claude"),
            AgentProcess(pid: 21, name: "chrome-native-host", executable: "/Applications/Claude.app/Contents/Helpers/chrome-native-host"),
            AgentProcess(pid: 22, name: "go", executable: "/opt/homebrew/bin/go"),
            AgentProcess(pid: 23, name: "Xcode"),
        ])
        XCTAssertNil(t.running(["Claude"]))
        XCTAssertEqual(t.running(["go"]), "go")
        XCTAssertEqual(t.running(["Xcode"]), "Xcode")
        let app = ProcessTable(entries: [AgentProcess(pid: 24, name: "Claude", executable: "/Applications/Claude.app/Contents/MacOS/Claude")])
        XCTAssertEqual(app.running(["Claude"]), "Claude")
    }

    // MARK: Claude

    func testLiveSessionsUseAliveCheck() throws {
        try write(".claude/sessions/100.json", #"{"pid":100,"sessionId":"aaa","cwd":"/w","startedAt":1791592021497,"status":"busy","name":"w-1","version":"2.1.296"}"#)
        try write(".claude/sessions/200.json", #"{"pid":200,"sessionId":"bbb","cwd":"/v"}"#)
        try write(".claude/sessions/300.json", "not json")
        let live = ClaudeSessions.live(AgentHome(home: home), alive: { $0 == 100 })
        XCTAssertEqual(live.map(\.sessionId), ["aaa"])
        XCTAssertEqual(live[0].cwd, "/w")
        XCTAssertEqual(live[0].status, "busy")
        XCTAssertEqual(live[0].startedAt.map { Int($0.timeIntervalSince1970) }, 1791592021)
    }

    func testInstalledPluginsBothFormats() throws {
        try write(".claude/plugins/installed_plugins.json", """
        {"version":2,"plugins":{
          "a@m":[{"scope":"user","installPath":"\(home)/.claude/plugins/cache/m/a/1.0.0/","version":"1.0.0"},
                 {"scope":"project","projectPath":"/p","installPath":"\(home)/.claude/plugins/cache/m/a/0.9.0"}],
          "b@m":{"installPath":"\(home)/.claude/plugins/cache/m/b/2.0.0"}}}
        """)
        let p = ClaudePlugins.installed(AgentHome(home: home))
        XCTAssertEqual(p.map(\.id), ["a@m", "a@m", "b@m"])
        XCTAssertEqual(p[1].installPath, home + "/.claude/plugins/cache/m/a/1.0.0", "trailing slash normalised")
        XCTAssertEqual(p[0].projectPath, "/p")
        XCTAssertEqual(p[2].scope, "user")
    }

    // MARK: guard

    func testGuardCoversCredentialsAndConfig() {
        let g = Guard(home: home)
        for rel in [".claude/settings.json", ".claude/.credentials.json", ".claude.json", ".codex/auth.json",
                    ".codex/config.toml", ".ssh/id_ed25519", ".claude/projects/-x/memory/MEMORY.md"] {
            XCTAssertNotNil(g.refusal(home + "/" + rel), rel)
        }
        XCTAssertNotNil(g.refusal(home + "/Documents/notes/a.txt"))
        XCTAssertNotNil(g.refusal(home + "/Library/Keychains/login.keychain-db"))
        XCTAssertNil(g.refusal(home + "/.claude/plugins/cache/m/a/0.9.0"))
        XCTAssertNil(g.refusal(home + "/Downloads/old.dmg"), "old installers may go")
    }
}
