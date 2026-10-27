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

    override func setUp() { L10n.override = .english }
    override func tearDown() { L10n.override = nil }

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
}
