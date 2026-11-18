@testable import CleanKit
import AgentCore
import ThermoL10n
import XCTest

/// Replays the 2026-11-18 freeze: a codex app-server up for nine days holding a full tool set per
/// thread, in projects that were all in use, so the "idle for two hours" test freed almost nothing.
final class ToolProcessesTests: XCTestCase {
    let mb = 1024
    let home = NSHomeDirectory()
    override func setUp() { L10n.override = .english }
    override func tearDown() { L10n.override = nil }

    func process(_ pid: Int32, _ ppid: Int32, _ name: String, _ exe: String, _ argv: [String], cwd: String? = nil,
                 cpu: Double = 0, kb: Int = 0, elapsed: TimeInterval = 90_000) -> SlowdownProcess {
        .init(pid: pid, ppid: ppid, name: name, executable: exe, argv: argv, cwd: cwd, cpu: cpu, footprintKB: kb,
              elapsed: elapsed, started: Date(timeIntervalSince1970: 1_000_000 + Double(pid)))
    }

    func incident() -> [SlowdownProcess] {
        let node = "/opt/homebrew/bin/node"
        var ps = [process(1, 0, "launchd", "/sbin/launchd", [])]
        ps[0].uid = 0
        ps.append(process(58_828, 1, "codex", "\(home)/.codex/packages/app-server-daemon/bin/codex", ["codex", "app-server", "--listen", "unix://"], kb: 4000 * mb, elapsed: 780_000))
        var next: Int32 = 60_000
        func pid() -> Int32 { next += 1; return next }
        for _ in 0..<38 {
            // codegraph is a wrapper with a server and a watchdog under it: three processes a copy.
            let root = pid()
            ps.append(process(root, 58_828, "node", node, ["node", "/opt/homebrew/bin/codegraph", "serve", "--mcp"], cwd: "\(home)/work/app", kb: 10 * mb))
            ps.append(process(pid(), root, "node", node, ["node", "--liftoff-only", "/x/codegraph.js", "serve", "--mcp"], cwd: "\(home)/work/app", kb: 60 * mb))
            ps.append(process(pid(), root, "node", node, ["node", "-e", "const fs = require('fs')"], cwd: "\(home)/work/app", kb: 15 * mb))
        }
        for _ in 0..<40 { ps.append(process(pid(), 58_828, "node", node, ["node", "\(home)/work/tools/mcp-feedback-channel.mjs"], kb: 35 * mb)) }
        for _ in 0..<73 { ps.append(process(pid(), 58_828, "node_repl", "\(home)/.cache/codex-runtimes/bin/node_repl", ["node_repl"], kb: 7 * mb)) }
        // A thread that is working right now: a young copy, a busy copy, and its shell with a build.
        ps.append(process(70_001, 58_828, "node", node, ["node", "/opt/homebrew/bin/codegraph", "serve", "--mcp"], kb: 80 * mb, elapsed: 600))
        ps.append(process(70_002, 58_828, "node", node, ["node", "/opt/homebrew/bin/rea", "mcp"], cpu: 40, kb: 300 * mb))
        ps.append(process(70_003, 58_828, "zsh", "/bin/zsh", ["zsh", "-c", "swift build"], kb: 3 * mb))
        ps.append(process(70_004, 70_003, "swift-build", "/usr/bin/swift-build", ["swift-build"], cpu: 300, kb: 900 * mb))
        // A Claude Code session in a terminal with its own tools.
        ps.append(process(80_000, 1, "zsh", "/bin/zsh", ["-zsh"]))
        ps.append(process(80_001, 80_000, "claude", "\(home)/.local/share/claude/versions/2.1.0/claude", ["claude"], cwd: "\(home)/work/app", kb: 400 * mb))
        ps.append(process(80_002, 80_001, "node", node, ["node", "/opt/homebrew/bin/codegraph", "serve", "--mcp"], kb: 90 * mb))
        ps.append(process(80_003, 80_001, "iphone-use-mcp", "\(home)/Applications/iPhoneUse.app/Contents/MacOS/iphone-use-mcp", ["iphone-use-mcp"], kb: 5 * mb))
        // A daemon started on purpose under launchd, with MCP in its command: a service, not a leftover.
        ps.append(process(90_002, 1, "chatgpt-use", "\(home)/.local/bin/chatgpt-use", ["chatgpt-use", "mcp", "--port", "51823"], kb: 20 * mb))
        // Left behind by a session that is gone.
        ps.append(process(90_001, 1, "node", node, ["node", "/opt/homebrew/bin/codegraph", "serve", "--mcp"], kb: 70 * mb))
        return ps
    }

    func testInventoryCountsEveryCopyPerHostAndMarksOnlyTheLeftBehindOnes() throws {
        let groups = ToolProcesses.inventory(incident(), me: 999_999, starterExited: { $0.pid == 90_001 })
        func group(_ name: String, _ kind: ToolProcessGroup.HostKind) -> ToolProcessGroup? { groups.first { $0.name == name && $0.hostKind == kind } }

        let codegraph = try XCTUnwrap(group("codegraph", .sharedService))
        XCTAssertEqual(codegraph.copies.count, 39)
        XCTAssertEqual(codegraph.processes, 38 * 3 + 1, "a copy is its whole tree")
        XCTAssertEqual(codegraph.rescueCopies.count, 38, "the ten-minute-old copy belongs to a thread that may be working")
        XCTAssertEqual(codegraph.rescueKB, 38 * 85 * mb)
        XCTAssertEqual(codegraph.hostPID, 58_828)
        XCTAssertEqual(group("mcp-feedback-channel.mjs", .sharedService)?.rescueCopies.count ?? group("mcp-feedback-channel", .sharedService)?.rescueCopies.count, 40,
                       "a script named after MCP is a tool even when the command is plain node")
        XCTAssertEqual(group("node_repl", .sharedService)?.rescueCopies.count, 73)
        XCTAssertEqual(group("rea", .sharedService)?.rescueCopies.count, 0, "a copy using the CPU is in use")

        let session = try XCTUnwrap(group("codegraph", .session))
        XCTAssertEqual(session.copies.count, 1)
        XCTAssertTrue(session.rescueCopies.isEmpty, "tools of a terminal session are that session's to keep")
        XCTAssertEqual(session.hostProject, "\(home)/work/app")
        XCTAssertEqual(group("codegraph", .none)?.rescueCopies.count, 1)

        let all = Set(groups.flatMap(\.identities).map(\.pid))
        XCTAssertFalse(all.contains(70_003) || all.contains(70_004), "a thread's shell and build are its work")
        XCTAssertFalse(all.contains(58_828) || all.contains(80_001), "hosts are never targets")
        XCTAssertFalse(all.contains(80_003), "a tool inside an app bundle is left to its app")
        XCTAssertFalse(all.contains(90_002), "a daemon under launchd whose own group it leads was started on purpose")
        let lines = ToolProcesses.summary(groups)
        XCTAssertEqual(lines.first?.name, "codegraph"); XCTAssertEqual(lines.first?.hostKind, .sharedService)
        XCTAssertEqual(lines.first { $0.name == "codegraph" && $0.hostKind == .session }?.hosts, 1)

        let rescue = ToolProcesses.rescueIdentities(groups)
        XCTAssertEqual(rescue.count, 38 * 3 + 40 + 73 + 1)
    }

    func testThePileIsReportedBeforeMemoryIsTightAndOnlyOnceAnHour() {
        let groups = ToolProcesses.inventory(incident(), me: 999_999, starterExited: { $0.pid == 90_001 })
        var alerts = SlowdownAlerts()
        let now = Date()
        let fired = alerts.evaluateTools(groups, now: now)
        XCTAssertEqual(fired.map(\.action), [SlowdownAlerts.toolsAction])
        XCTAssertEqual(fired.first?.title.contains("228"), true)
        XCTAssertTrue(alerts.evaluateTools(groups, now: now.addingTimeInterval(600)).isEmpty)
        XCTAssertEqual(alerts.evaluateTools(groups, now: now.addingTimeInterval(3700)).count, 1)
        // A couple of strays are not worth a notification.
        var quiet = SlowdownAlerts()
        let few = ToolProcesses.inventory(incident().filter { $0.pid >= 80_000 || $0.pid == 1 }, me: 999_999, starterExited: { $0.pid == 90_001 })
        XCTAssertTrue(quiet.evaluateTools(few, now: now).isEmpty)
    }

    func testAnythingLeadingToTheCallerIsLeftOut() {
        var ps = incident()
        // The CLI was started from a tool of that Codex thread.
        ps.append(process(95_000, 60_001, "thermo-cli", "/usr/local/bin/tool", ["tool"]))
        let groups = ToolProcesses.inventory(ps, me: 95_000, starterExited: { _ in false })
        XCTAssertFalse(groups.flatMap(\.identities).contains { $0.pid == 60_001 })
        XCTAssertTrue(groups.isEmpty || groups.allSatisfy { $0.hostPID != 58_828 }, "the host above the caller keeps all its tools")
    }

    func testEndingSignalsOnlyWhatStillMatchesAndReportsTheRest() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        var real: ProcessIdentity?
        for _ in 0..<50 where real == nil { real = ProcessTable.identity(child.processIdentifier); usleep(20_000) }
        let identity = try XCTUnwrap(real)
        var stale = identity; stale.started = identity.started.addingTimeInterval(-60)
        let tmp = NSTemporaryDirectory() + "com.example.tools-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let outcome = ToolProcesses.end([identity, stale], memoryKB: [identity.pid: 2048], subject: "test", grace: 3, journalHome: tmp)
        XCTAssertEqual(outcome.asked, 1); XCTAssertEqual(outcome.ended, 1); XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(outcome.stillRunning, 0); XCTAssertEqual(outcome.freedKB, 2048)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
    }
}
