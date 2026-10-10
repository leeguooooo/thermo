@testable import AgentDoctor
import ThermoL10n
import XCTest

final class ActionTests: XCTestCase {
    var home: URL!
    let fm = FileManager.default
    var executed: [[String]] = []
    var signalled: [Int32] = []
    var trashed: [String] = []
    var psArgs: [Int32: String] = [:]

    override func setUpWithError() throws {
        L10n.override = .english
        home = fm.temporaryDirectory.appendingPathComponent("actions-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        executed = []; signalled = []; trashed = []; psArgs = [:]
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: home) }

    var env: DoctorEnvironment {
        var e = DoctorEnvironment(home: home, uid: 501, path: ["/bin"], run: { [unowned self] tool, args in
            if tool == "/bin/ps", let p = args.last.flatMap(Int32.init) { return self.psArgs[p] }
            return nil
        })
        e.execute = { [unowned self] tool, args, _ in self.executed.append([tool] + args); return (0, "") }
        e.signal = { [unowned self] pid, _ in self.signalled.append(pid); return true }
        e.trash = { [unowned self] url in self.trashed.append(url.path); try FileManager.default.removeItem(at: url) }
        return e
    }

    func path(_ p: String) -> String { home.appendingPathComponent(p).path }

    func write(_ p: String, _ text: String) throws {
        let u = home.appendingPathComponent(p)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }

    func act(_ steps: [Step]) -> ActionResult {
        ActionRunner.perform(Action(id: "t", kind: .fix, title: "t", summary: "", steps: steps, destructive: false), env: env)
    }

    func testFailedStepIsLoggedAndItsOutputIsRedacted() throws {
        try write(".local/bin/fixture-tool", "#!/bin/sh\nexit 1\n")
        let executable = path(".local/bin/fixture-tool")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)
        var called = false
        var environment = env
        environment.execute = { _, _, _ in called = true; return (1, "API_TOKEN=fixture-sensitive-value") }
        let action = Action(id: "fixture-failure", kind: .fix, title: "Fixture", summary: "",
                            steps: [.run(tool: executable, args: [], cwd: nil)], destructive: false)
        let result = ActionRunner.perform(action, env: environment)
        XCTAssertTrue(called)
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.log.joined().contains("API_TOKEN="))
        XCTAssertFalse(result.log.joined().contains("fixture-sensitive-value"))
        let log = try String(contentsOf: environment.logFile)
        XCTAssertTrue(log.contains("fixture-failure"))
        XCTAssertTrue(log.contains("failed:"))
        XCTAssertFalse(log.contains("fixture-sensitive-value"))
    }

    func testUnlinkRemovesLinkNotTarget() throws {
        try write(".agents/skills/x/SKILL.md", "---\ndescription: d\n---")
        try fm.createDirectory(at: home.appendingPathComponent(".claude/skills"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: path(".claude/skills/x"), withDestinationPath: path(".agents/skills/x"))
        XCTAssertTrue(act([.unlink(path: path(".claude/skills/x"))]).ok)
        XCTAssertFalse(fm.fileExists(atPath: path(".claude/skills/x")))
        XCTAssertTrue(fm.fileExists(atPath: path(".agents/skills/x/SKILL.md")), "target must survive")
        // A real folder is never unlinked.
        XCTAssertFalse(act([.unlink(path: path(".agents/skills/x"))]).ok)
    }

    func testRemoveKeyBacksUpFirst() throws {
        try write(".cursor/mcp.json", #"{"mcpServers": {"a": {"command": "x"}, "b": {"command": "y"}}}"#)
        let r = act([.removeJSONKey(file: path(".cursor/mcp.json"), path: ["mcpServers", "a"])])
        XCTAssertTrue(r.ok)
        let now = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path(".cursor/mcp.json")))) as? [String: Any])
        XCTAssertEqual((now["mcpServers"] as? [String: Any])?.keys.sorted(), ["b"])
        let backup = try XCTUnwrap(r.backups.first)
        XCTAssertTrue(try String(contentsOfFile: backup).contains("\"a\""), "backup holds the original")
        XCTAssertTrue(backup.hasPrefix(path("Library/Application Support/Thermo/Backups")))
        XCTAssertTrue(try String(contentsOfFile: path("Library/Logs/Thermo/fix.log")).contains("fix t"))
    }

    func testRemoveHookChecksCommand() throws {
        try write(".claude/settings.json", #"{"hooks": {"Stop": [{"hooks": [{"command": "a"}, {"command": "b"}]}]}, "model": "x"}"#)
        let file = path(".claude/settings.json")
        XCTAssertFalse(act([.removeHook(file: file, event: "Stop", group: 0, hook: 0, command: "changed")]).ok)
        XCTAssertTrue(act([.removeHook(file: file, event: "Stop", group: 0, hook: 0, command: "a")]).ok)
        XCTAssertTrue(act([.removeHook(file: file, event: "Stop", group: 0, hook: 0, command: "b")]).ok)
        let now = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any])
        XCTAssertNil((now["hooks"] as? [String: Any])?["Stop"], "empty event removed")
        XCTAssertEqual(now["model"] as? String, "x", "other settings kept")
    }

    func testKillRechecksCommandLine() {
        psArgs = [10: "/x/server --a", 11: "/bin/something-else"]
        let r = act([.kill(pid: 10, args: "/x/server --a"), .kill(pid: 11, args: "/x/server --a")])
        XCTAssertFalse(r.ok)
        XCTAssertEqual(signalled, [10], "pid 11 was reused by another program")
        // Already gone counts as done.
        XCTAssertTrue(act([.kill(pid: 99, args: "x")]).ok)
    }

    func testGuardRefusesProtectedPaths() throws {
        try write(".ssh/config", "x")
        XCTAssertFalse(act([.trash(path: path(".ssh/config"))]).ok)
        XCTAssertFalse(act([.trash(path: path(".claude"))]).ok, "never a whole agent home")
        XCTAssertFalse(act([.trash(path: "/etc/hosts")]).ok)
        XCTAssertTrue(trashed.isEmpty)
    }

    func testKeepAliveRewrite() throws {
        let d: [String: Any] = ["Label": "x", "ProgramArguments": ["/bin/sh"], "KeepAlive": true]
        let plist = path("Library/LaunchAgents/x.plist")
        try fm.createDirectory(atPath: (plist as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0).write(to: URL(fileURLWithPath: plist))
        let r = act([.keepAliveOnFailure(plist: plist, label: "x")])
        XCTAssertTrue(r.ok)
        let now = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: plist)), format: nil) as? [String: Any]
        XCTAssertEqual(now?["KeepAlive"] as? [String: Bool], ["SuccessfulExit": false])
        XCTAssertEqual(executed.map { $0[1] }, ["bootout", "bootstrap"])
        XCTAssertEqual(r.backups.count, 1)
    }

    /// The doctor offers the right action per item, and never one that edits plugin files.
    func testOfferedActions() throws {
        try write(".claude/settings.json", #"{"hooks": {"Stop": [{"hooks": [{"command": "true"}]}]}}"#)
        try write(".cursor/mcp.json", #"{"mcpServers": {"gone": {"command": "/nope"}}}"#)
        try fm.createDirectory(at: home.appendingPathComponent(".claude/skills"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: path(".claude/skills/dead"), withDestinationPath: "/nope")
        let r = AgentDoctor.run(env)
        let hook = try XCTUnwrap(r.items.first { $0.area == .hooks })
        XCTAssertEqual(hook.actions.map(\.kind), [.uninstall])
        let mcp = try XCTUnwrap(r.items.first { $0.name == "gone" })
        XCTAssertEqual(mcp.actions.first?.steps, [.removeJSONKey(file: path(".cursor/mcp.json"), path: ["mcpServers", "gone"])])
        let dead = try XCTUnwrap(r.items.first { $0.name == "dead" })
        XCTAssertEqual(dead.actions.first?.kind, .fix)
        XCTAssertEqual(dead.actions.first?.steps, [.unlink(path: path(".claude/skills/dead"))])
    }
}
