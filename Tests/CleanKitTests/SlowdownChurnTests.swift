@testable import CleanKit
import AgentCore
import ThermoL10n
import XCTest

/// Two patterns a single process snapshot hides: a daemon re-spawning short-lived workers
/// (wechat-use `wechatd run`, 2026-10-27), and one MCP server idling in every session (rea ×31).
final class SlowdownChurnTests: XCTestCase {
    let mb = 1024
    let gb = 1_048_576
    let home = NSHomeDirectory()

    override func setUp() { L10n.override = .english; SessionActivity.current = SessionActivity(home: "/nonexistent-thermo-test") }
    override func tearDown() { L10n.override = nil; SessionActivity.current = SessionActivity() }

    func system(swapUsed: Double = 15.5, swapTotal: Double = 16, pressure: MachinePulse.Memory = .warning, load: Double = 6) -> SlowdownSystem {
        SlowdownSystem(memoryBytes: 16 << 30, swapUsed: UInt64(swapUsed * Double(1 << 30)), swapTotal: UInt64(swapTotal * Double(1 << 30)),
                       pressure: pressure, load1: load, cores: 10)
    }

    func churn() -> [SlowdownProcess] {
        let sdk = "\(home)/.local/share/wechat-use/sdk/versions/g-d4a6"
        var wechatd = SlowdownProcess(pid: 4749, ppid: 97124, name: "wechatd", executable: "\(sdk)/wechatd", argv: ["\(sdk)/wechatd", "run"],
                                      cpu: 0.5, footprintKB: 40 * mb, elapsed: 27 * 3600)
        wechatd.childCPU = 38; wechatd.childCPULifetime = 41
        wechatd.youngChildren = ["snapshot_runtime": 3]
        // A terminal shell that ran long builds: busy children, but that is the person's work.
        var shell = SlowdownProcess(pid: 900, ppid: 2085, name: "zsh", executable: "/bin/zsh", elapsed: 5 * 3600)
        shell.childCPU = 300; shell.childCPULifetime = 80; shell.youngChildren = ["swift-frontend": 12]
        return [
            .init(pid: 97124, ppid: 1, name: "wechat-bridge", executable: "\(sdk)/wechat-bridge", elapsed: 30 * 3600),
            wechatd,
            // What `top` shows: one 9-second-old Python.
            .init(pid: 65213, ppid: 4749, name: "Python", executable: "/opt/homebrew/Cellar/python@3.14/3.14.9/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python",
                  argv: ["python3.14", "-I", "\(home)/.wx-rs/snapshot-runtime/snapshot_runtime.py"], cpu: 50, footprintKB: 30 * mb, elapsed: 9),
            .init(pid: 2085, ppid: 1, name: "cmux", executable: "/Applications/cmux.app/Contents/MacOS/cmux", elapsed: 90_000),
            shell,
        ]
    }

    func testRespawnChurnIsOneCulpritOnTheParent() {
        let d = SlowdownDiagnosis.diagnose(churn(), system: system(swapUsed: 1, swapTotal: 2, pressure: .normal, load: 4), me: 1,
                                           launchdLabel: { $0.hasSuffix("/wechat-bridge") ? "ai.wechat.bridge" : nil }, packageVersion: { _ in nil })
        let c = d.culprits.first { $0.kind == .respawnChurn }
        XCTAssertEqual(c?.pids, [4749])
        XCTAssertEqual(c?.name, "wechatd")
        XCTAssertTrue(c?.evidence.contains("snapshot_runtime") == true && c?.evidence.contains("41%") == true, c?.evidence ?? "")
        XCTAssertTrue(c?.guidance.contains("wechat-use") == true, c?.guidance ?? "")
        XCTAssertTrue(c?.guidance.contains("author") == true)
        XCTAssertEqual(c?.command, "launchctl kickstart -k gui/\(getuid())/ai.wechat.bridge", "stop it the way it was started, not kill")
        XCTAssertEqual(c?.action, .review, "ending the worker is pointless and the daemon is not killed")
        XCTAssertFalse((d.culprits + d.also).contains { $0.pids.first == 900 }, "a shell's builds are not churn")
        XCTAssertFalse((d.culprits + d.also).contains { $0.pids.first == 65213 }, "the visible worker is not the culprit")
    }

    func testChurnWithoutLaunchAgentSuggestsItsOwnStopCommand() {
        let d = SlowdownDiagnosis.diagnose(churn(), system: system(), me: 1, launchdLabel: { _ in nil }, packageVersion: { _ in nil })
        let c = d.culprits.first { $0.kind == .respawnChurn }
        XCTAssertNil(c?.command)
        XCTAssertTrue(c?.guidance.contains("`wechatd stop`") == true, c?.guidance ?? "")
    }

    func testShortLivedNewDaemonIsNotChurn() {
        var ps = churn()
        ps[1].elapsed = 120
        let d = SlowdownDiagnosis.diagnose(ps, system: system(), me: 1, launchdLabel: { _ in nil }, packageVersion: { _ in nil })
        XCTAssertFalse(d.culprits.contains { $0.kind == .respawnChurn })
    }

    /// 18 `rea mcp` left under one codex app-server from finished sessions, 13 under live Claude sessions.
    func idleMCP() -> [SlowdownProcess] {
        var ps: [SlowdownProcess] = [
            .init(pid: 2085, ppid: 1, name: "cmux", executable: "/Applications/cmux.app/Contents/MacOS/cmux", footprintKB: 800 * mb, elapsed: 300_000),
            .init(pid: 39123, ppid: 2085, name: "codex", executable: "\(home)/.local/bin/codex", argv: ["codex"], cwd: "\(home)/github.com/camera-use",
                  footprintKB: 200 * mb, elapsed: 130_000),
            .init(pid: 39971, ppid: 39123, name: "codex", executable: "\(home)/.codex/packages/app-server-daemon/bin/codex",
                  argv: ["codex", "app-server"], footprintKB: 1900 * mb, elapsed: 130_000),
        ]
        var next: Int32 = 1000
        func rea(_ parent: Int32) -> SlowdownProcess {
            next += 1
            return .init(pid: next, ppid: parent, name: "node", executable: "/opt/homebrew/Cellar/node/24.1/bin/node",
                         argv: ["node", "/opt/homebrew/bin/rea", "mcp"], cpu: 0, footprintKB: 230 * mb, elapsed: 80_000)
        }
        for _ in 0..<18 { ps.append(rea(39971)) }
        for i in 0..<13 {
            let claude = Int32(5000 + i)
            ps.append(.init(pid: claude, ppid: 2085, name: "claude", executable: "\(home)/.local/share/claude/versions/2.1.0/claude",
                            argv: ["claude"], cwd: "\(home)/p\(i)", cpu: 1, footprintKB: 450 * mb, elapsed: 20_000))
            ps.append(rea(claude))
        }
        return ps
    }

    func testIdleMCPAcrossSessionsIsATopCulprit() {
        let d = SlowdownDiagnosis.diagnose(idleMCP(), system: system(), me: 1, launchdLabel: { _ in nil },
                                           packageVersion: { $0.argv.contains("/opt/homebrew/bin/rea") ? PackageVersion(name: "rea-agents", version: "6.7.0") : nil })
        guard let c = d.culprits.first(where: { $0.kind == .idleMCP }) else { return XCTFail(d.culprits.map(\.name).joined(separator: ",")) }
        XCTAssertEqual(d.culprits.first?.id, c.id, "the biggest reclaimable memory comes first")
        XCTAssertEqual(c.name, "rea MCP server")
        XCTAssertEqual(c.children, 31)
        XCTAssertEqual(c.memoryKB, 31 * 230 * mb)
        XCTAssertEqual(c.freesKB, 18 * 230 * mb, "only the leaked copies are reclaimable without closing sessions")
        XCTAssertTrue(c.evidence.contains("18 of them belong to sessions that already ended"), c.evidence)
        XCTAssertTrue(c.guidance.contains("PID 39971") && c.guidance.contains("PID 39123"), c.guidance)
        XCTAssertTrue(c.guidance.contains("230 MiB per session × 31"), c.guidance)
        XCTAssertTrue(c.guidance.contains("rea-agents 6.7.0"), c.guidance)
        XCTAssertTrue(d.headline.contains("rea MCP server"), d.headline)
    }

    func testOrphanedMCPCopiesCanBeEnded() {
        var ps = idleMCP()
        for i in ps.indices where ps[i].ppid == 39971 { ps[i].ppid = 1; ps[i].started = Date(); ps[i].executable = "/opt/homebrew/bin/node" }
        let d = SlowdownDiagnosis.diagnose(ps, system: system(), me: 1, launchdLabel: { _ in nil }, packageVersion: { _ in nil })
        let c = d.culprits.first { $0.kind == .idleMCP }
        XCTAssertEqual(c?.action, .end)
        XCTAssertTrue(c?.command?.hasPrefix("thermo pulse end ") == true)
        XCTAssertEqual(c?.identities?.count, 18)
    }

    func testHeadlineCountsSharedProcessesOnce() {
        // Add enough leaked helpers that the app-server is itself a leaky parent covering the same rea copies.
        var ps = idleMCP()
        for i in 0..<30 {
            ps.append(.init(pid: Int32(8000 + i), ppid: 39971, name: "node_repl", executable: "/opt/tools/node_repl", argv: ["node_repl"],
                            cpu: 0, footprintKB: 10 * mb, elapsed: 80_000))
        }
        let d = SlowdownDiagnosis.diagnose(ps, system: system(), me: 1, launchdLabel: { _ in nil }, packageVersion: { _ in nil })
        XCTAssertTrue(d.culprits.contains { $0.kind == .leakyParent })
        XCTAssertTrue(d.culprits.contains { $0.kind == .idleMCP })
        let leak = 1900 * mb + 18 * 230 * mb + 30 * 10 * mb
        let idleSessions = 13 * (450 + 230) * mb + 200 * mb  // the 13 Claude sessions and the idle codex session
        XCTAssertTrue(d.culprits.contains { $0.kind == .agentSessions })
        let expected = MemoryFormat.string(kibibytes: leak + idleSessions)
        XCTAssertTrue(d.headline.contains(expected), "\(d.headline) should free \(expected), not count the rea copies twice")
    }

    /// What the user did by hand: end the copies of idle sessions, keep the ones of active projects.
    func testIdleSessionCopiesAreEndableAndActiveOnesKept() {
        var ps = idleMCP()
        // Six app-server copies work for camera-use (active now), the other twelve for projects idle since this morning.
        var n = 0
        for i in ps.indices where ps[i].ppid == 39971 {
            ps[i].cwd = n < 6 ? "\(home)/github.com/camera-use" : "\(home)/old\(n)"
            ps[i].started = Date(timeIntervalSinceNow: -80_000); n += 1
        }
        // Two Claude sessions have not written their transcript for 5 hours.
        let now = Date()
        let activity: (String) -> Date? = { cwd in
            if cwd.hasSuffix("/camera-use") { return now.addingTimeInterval(-60) }
            if cwd.hasSuffix("/p0") || cwd.hasSuffix("/p1") { return now.addingTimeInterval(-5 * 3600) }
            if cwd.contains("/p") { return now.addingTimeInterval(-300) }
            return now.addingTimeInterval(-6 * 3600)
        }
        for i in ps.indices where ps[i].ppid >= 5000 { ps[i].started = Date(timeIntervalSinceNow: -20_000) }
        let d = SlowdownDiagnosis.diagnose(ps, system: system(), me: 1, sampled: now, launchdLabel: { _ in nil },
                                           packageVersion: { _ in nil }, lastActivity: activity)
        guard let c = (d.culprits + d.also).first(where: { $0.kind == .idleMCP }) else { return XCTFail("no idle MCP culprit") }
        XCTAssertEqual(c.action, .end)
        XCTAssertEqual(c.identities?.count, 14, "12 idle app-server copies + 2 idle Claude sessions")
        XCTAssertEqual(c.freesKB, 14 * 230 * mb)
        XCTAssertTrue(c.guidance.contains("~/github.com/camera-use"), c.guidance)
        let ended = Set(c.identities!.map(\.pid))
        XCTAssertFalse(ps.contains { ended.contains($0.pid) && $0.cwd?.hasSuffix("/camera-use") == true })
    }

    func testSessionsGroupTheirMCPServers() {
        var ps = idleMCP()
        var n = 0
        for i in ps.indices where ps[i].ppid == 39971 { ps[i].cwd = n < 6 ? "/w/active" : "/w/old"; n += 1 }
        ps.append(.init(pid: 9999, ppid: 1, name: "node", executable: "/opt/homebrew/bin/node", argv: ["node", "/opt/homebrew/bin/rea", "mcp"], footprintKB: 230 * mb))
        let now = Date()
        let groups = AgentSessionGroup.group(ps, now: now, lastActivity: { $0 == "/w/active" ? now : $0 == "/w/old" ? now.addingTimeInterval(-9000) : nil })
        let old = groups.first { $0.cwd == "/w/old" }
        XCTAssertEqual(old?.idle, true)
        XCTAssertEqual(old?.servers.first?.pids.count, 12)
        XCTAssertEqual(groups.first { $0.cwd == "/w/active" }?.idle, false)
        XCTAssertEqual(groups.first { $0.pid == 5000 }?.servers.first?.name, "rea MCP server")
        XCTAssertEqual(groups.first { $0.pid == 5000 }?.idle, false, "unknown activity is not idle")
        XCTAssertEqual(groups.first { $0.title == "MCP servers without a session" }?.servers.first?.pids, [9999])
    }

    /// The emulator a dice Codex session started under the shared app-server, while that session is in use.
    func emulator(activeAgo: TimeInterval) -> SlowdownDiagnosis {
        var ps = idleMCP()
        for i in ps.indices where ps[i].ppid == 39971 { ps[i].cwd = "\(home)/github.com/camera-use" }
        ps.append(.init(pid: 61574, ppid: 39971, name: "qemu-system-aarch64-headless", executable: "/opt/android/emulator/qemu-system-aarch64-headless",
                        argv: ["qemu-system-aarch64-headless", "-avd", "DiceRivals_Play_Timing"], cwd: "\(home)/tk.com/dice",
                        cpu: 92, cpuLifetime: 85, busyFor: 3600, footprintKB: 6 * gb, elapsed: 3700, started: Date(timeIntervalSinceNow: -3700)))
        let now = Date()
        return SlowdownDiagnosis.diagnose(ps, system: system(), me: 1, sampled: now, launchdLabel: { _ in nil }, packageVersion: { _ in nil },
                                          lastActivity: { $0.hasSuffix("/tk.com/dice") ? now.addingTimeInterval(-activeAgo) : $0.hasSuffix("/camera-use") ? now.addingTimeInterval(-60) : nil })
    }

    func testAppServerChildIsAttributedToItsOwnProjectAndActiveOnesHaveNoEndButton() {
        let d = emulator(activeAgo: 180)
        guard let qemu = (d.culprits + d.also).first(where: { $0.pids.first == 61574 }) else { return XCTFail("emulator not listed") }
        XCTAssertTrue(qemu.launcher?.contains("~/tk.com/dice") == true, qemu.launcher ?? "")
        XCTAssertFalse(qemu.launcher?.contains("camera-use") == true, "not the app-server's own folder")
        XCTAssertEqual(qemu.action, .review)
        XCTAssertNil(qemu.command)
        XCTAssertTrue(qemu.guidance.contains("~/tk.com/dice") && qemu.guidance.contains("in use"), qemu.guidance)
    }

    func testIdleProjectEmulatorCanBeEnded() {
        let d = emulator(activeAgo: 5 * 3600)
        let qemu = (d.culprits + d.also).first { $0.pids.first == 61574 }
        XCTAssertEqual(qemu?.action, .end)
        XCTAssertEqual(qemu?.command, "thermo pulse end 61574")
    }

    func testSharedAppServerGuidanceNamesTheProjectsItInterrupts() {
        var ps = idleMCP()
        for (n, i) in ps.indices.filter({ ps[$0].ppid == 39971 }).enumerated() { ps[i].cwd = n < 9 ? "\(home)/github.com/camera-use" : "\(home)/tk.com/dice" }
        for i in 0..<30 {
            ps.append(.init(pid: Int32(8000 + i), ppid: 39971, name: "node_repl", executable: "/opt/tools/node_repl", argv: ["node_repl"], cwd: "\(home)/old", footprintKB: 10 * mb))
        }
        let now = Date()
        let d = SlowdownDiagnosis.diagnose(ps, system: system(), me: 1, sampled: now, launchdLabel: { _ in nil }, packageVersion: { _ in nil },
                                           lastActivity: { $0.hasSuffix("/dice") ? now : nil })
        let leak = d.culprits.first { $0.kind == .leakyParent }
        XCTAssertTrue(leak?.guidance.contains("3 projects") == true, leak?.guidance ?? "")
        XCTAssertTrue(leak?.guidance.contains("~/tk.com/dice") == true, leak?.guidance ?? "")
        XCTAssertTrue(leak?.guidance.contains("PID 39123") == true)
    }

    func testSessionActivityReadsLongRunningCodexAndClaudeTranscripts() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("activity-" + UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        // Started five days ago, still written now; its first line embeds long instructions.
        let day = home + "/.codex/sessions/2026/10/22"
        try FileManager.default.createDirectory(atPath: day, withIntermediateDirectories: true)
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"x\",\"cwd\":\"/Users/u/tk.com/dice\",\"base_instructions\":{\"text\":\"" + String(repeating: "a", count: 40_000) + "\"}}}\n"
        FileManager.default.createFile(atPath: day + "/rollout.jsonl", contents: Data(meta.utf8))
        let claude = home + "/.claude/projects/-Users-u-github-com-camera-use"
        try FileManager.default.createDirectory(atPath: claude, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: claude + "/s.jsonl", contents: Data("{}\n".utf8))
        let activity = SessionActivity(home: home)
        XCTAssertNotNil(activity.last(cwd: "/Users/u/tk.com/dice"))
        XCTAssertNotNil(activity.last(cwd: "/Users/u/github.com/camera-use"))
        XCTAssertNil(activity.last(cwd: "/Users/u/elsewhere"))
    }
}
