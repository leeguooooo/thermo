@testable import CleanKit
import AgentCore
import ThermoL10n
import XCTest

/// Replays the 2026-10-27 incident behind issues #10 and #11 (16 GB Mac, swap 16.7 of 17.4 GB,
/// load 24–35) and checks that the real culprits come out on top with the right advice.
final class SlowdownDiagnosisTests: XCTestCase {
    let me = getuid()
    let gb = 1_048_576
    let mb = 1024
    let home = NSHomeDirectory()

    override func setUp() { L10n.override = .english }
    override func tearDown() { L10n.override = nil }

    var incidentSystem: SlowdownSystem {
        SlowdownSystem(memoryBytes: 16 << 30, swapUsed: UInt64(16.7 * Double(1 << 30)), swapTotal: UInt64(17.4 * Double(1 << 30)),
                       pressure: .warning, load1: 30, cores: 10)
    }

    /// The process table as it was, reduced to what matters plus decoys.
    func incident() -> [SlowdownProcess] {
        var ps: [SlowdownProcess] = []
        var next: Int32 = 10_000
        func pid() -> Int32 { next += 1; return next }
        // System decoys: busy and big, never to be named.
        ps.append(.init(pid: 1, ppid: 0, uid: 0, name: "launchd", executable: "/sbin/launchd", elapsed: 200_000))
        ps.append(.init(pid: 150, ppid: 1, uid: 88, name: "WindowServer", executable: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                        cpu: 60, cpuLifetime: 40, footprintKB: 2 * gb, elapsed: 200_000))
        ps.append(.init(pid: 151, ppid: 1, uid: 0, name: "mds_stores", executable: "/System/Library/Frameworks/CoreServices.framework/mds_stores",
                        cpu: 95, cpuLifetime: 60, busyFor: 900, footprintKB: 300 * mb, elapsed: 200_000))
        ps.append(.init(pid: 152, ppid: 1, uid: me, name: "mediaanalysisd", executable: "/System/Library/PrivateFrameworks/MediaAnalysis.framework/mediaanalysisd",
                        cpu: 105, cpuLifetime: 70, busyFor: 600, footprintKB: 30 * mb, elapsed: 50_000))
        // The terminal and 17 Claude Code sessions, each with its MCP servers (codegraph among them).
        ps.append(.init(pid: 2085, ppid: 1, name: "cmux", executable: "/Applications/cmux.app/Contents/MacOS/cmux", cpu: 15, footprintKB: 900 * mb, elapsed: 300_000))
        for i in 0..<17 {
            let shell = pid(), claude = pid()
            ps.append(.init(pid: shell, ppid: 2085, name: "zsh", executable: "/bin/zsh", argv: ["-zsh"], footprintKB: 3 * mb, elapsed: 80_000))
            ps.append(.init(pid: claude, ppid: shell, name: "claude", executable: "\(home)/.local/share/claude/versions/2.1.0/claude",
                            argv: ["claude"], cwd: "\(home)/github.com/project\(i)", cpu: 1, footprintKB: 500 * mb, elapsed: 30_000))
            ps.append(.init(pid: pid(), ppid: claude, name: "node", executable: "/opt/homebrew/bin/node",
                            argv: ["node", "\(home)/.npm/codegraph/dist/codegraph.js", "serve", "--mcp", "--path", "\(home)/github.com/project\(i)"],
                            cwd: "\(home)/github.com/project\(i)", cpu: 0.2, footprintKB: 60 * mb, elapsed: 30_000))
        }
        // #10: the orphaned codegraph MCP server spinning after SIGTERM, writing its WAL.
        ps.append(.init(pid: 6217, ppid: 1, name: "node", executable: "/opt/homebrew/bin/node",
                        argv: ["node", "\(home)/.npm/codegraph/dist/codegraph.js", "serve", "--mcp", "--path", "\(home)/github.com/wechat-project"],
                        cwd: "\(home)/github.com/wechat-project", cpu: 160, cpuLifetime: 150, footprintKB: 600 * mb, elapsed: 25 * 60,
                        writeBytesPerSecond: 8_000_000, started: Date(timeIntervalSinceNow: -25 * 60)))
        // #11: codex app-server with a full MCP set per finished session, never reaped.
        let codexShell = pid()
        ps.append(.init(pid: codexShell, ppid: 2085, name: "zsh", executable: "/bin/zsh", footprintKB: 3 * mb, elapsed: 140_000))
        ps.append(.init(pid: 39123, ppid: codexShell, name: "codex", executable: "\(home)/.local/bin/codex", argv: ["codex"],
                        cwd: "\(home)/tk.com/dice", cpu: 2, footprintKB: 200 * mb, elapsed: 130_000))
        ps.append(.init(pid: 39971, ppid: 39123, name: "codex", executable: "\(home)/.codex/packages/app-server-daemon/bin/codex",
                        argv: ["codex", "app-server", "--listen", "unix://"], cwd: "\(home)/tk.com/dice", cpu: 3,
                        footprintKB: 1900 * mb, elapsed: 130_000))
        let sets: [(String, [String], Int)] = [
            ("node", ["node", "/opt/rea/dist/cli.js", "mcp"], 68), ("iphone-use-mcp", ["iphone-use-mcp"], 17),
            ("discord-use", ["discord-use", "mcp"], 17), ("python3", ["python3", "-m", "android_use.mcp"], 17),
            ("node_repl", ["node_repl"], 17), ("SkyComputerUse", ["SkyComputerUse", "mcp"], 17), ("android-use", ["android-use", "mcp"], 12),
        ]
        for (name, argv, count) in sets {
            for _ in 0..<count {
                ps.append(.init(pid: pid(), ppid: 39971, name: name, executable: "/opt/tools/\(name)", argv: argv,
                                cwd: "\(home)/tk.com/dice", cpu: 0.1, footprintKB: 12 * mb, elapsed: 100_000))
            }
        }
        // #11: the reverse-engineering tool started by a codex session, stuck for 22 hours on 3.1 GB.
        ps.append(.init(pid: 51234, ppid: 39971, name: "Il2CppInspector", executable: "\(home)/tools/Il2CppInspector.Redux.CLI",
                        argv: ["\(home)/tools/Il2CppInspector.Redux.CLI", "-i", "GameAssembly.dll"], cwd: "\(home)/tk.com/dice",
                        cpu: 1.8, cpuLifetime: 30, footprintKB: Int(3.1 * Double(gb)), elapsed: 22 * 3600,
                        started: Date(timeIntervalSinceNow: -22 * 3600)))
        // A big GUI app: suggested, never ended.
        ps.append(.init(pid: 96677, ppid: 1, name: "Douyin AR", executable: "/Applications/Douyin AR.app/Contents/MacOS/Douyin AR",
                        cpu: 35, footprintKB: 2 * gb, elapsed: 20_000))
        for _ in 0..<10 {
            ps.append(.init(pid: pid(), ppid: 96677, name: "Douyin AR Helper", executable: "/Applications/Douyin AR.app/Contents/Frameworks/Helper.app/Contents/MacOS/Douyin AR Helper",
                            cpu: 1, footprintKB: 100 * mb, elapsed: 20_000))
        }
        return ps
    }

    func testIncidentSnapshotRoundTripsAsJSON() throws {
        let snapshot = incident()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode([SlowdownProcess].self, from: data)
        XCTAssertEqual(decoded.map(\.pid), snapshot.map(\.pid))
        XCTAssertEqual(SlowdownDiagnosis.diagnose(decoded, system: incidentSystem, me: 99_999).culprits.map(\.id),
                       SlowdownDiagnosis.diagnose(snapshot, system: incidentSystem, me: 99_999).culprits.map(\.id))
    }

    func testIncidentRanksTheRealCulprits() {
        let d = SlowdownDiagnosis.diagnose(incident(), system: incidentSystem, me: 99_999)
        XCTAssertEqual(d.memoryStrain, .exhausted)
        XCTAssertTrue(d.isReal)
        XCTAssertEqual(d.culprits.count, 3)
        let kinds = Set(d.culprits.map(\.kind))
        XCTAssertEqual(kinds, [.leakyParent, .stuck, .orphan], d.culprits.map { "\($0.kind) \($0.name) \($0.score)" }.joined(separator: "\n"))

        let stuck = d.culprits.first { $0.kind == .stuck }!
        XCTAssertEqual(stuck.pids.first, 51234)
        XCTAssertEqual(stuck.action, .end)
        XCTAssertEqual(stuck.command, "thermo pulse end 51234")
        XCTAssertGreaterThanOrEqual(stuck.freesKB, 3 * gb)
        XCTAssertTrue(stuck.launcher?.contains("codex app-server · PID 39971") == true, stuck.launcher ?? "")

        let leak = d.culprits.first { $0.kind == .leakyParent }!
        XCTAssertEqual(leak.pids, [39971])
        XCTAssertEqual(leak.children, 165, "the stuck tool is its own culprit, not one of the leaked helpers")
        XCTAssertEqual(leak.action, .review)
        XCTAssertTrue(leak.guidance.contains("PID 39123"), leak.guidance)
        XCTAssertTrue(leak.evidence.contains("×68"), leak.evidence)

        let orphan = d.culprits.first { $0.kind == .orphan }!
        XCTAssertEqual(orphan.pids.first, 6217)
        XCTAssertEqual(orphan.name, "codegraph MCP server")
        XCTAssertEqual(orphan.action, .end)
        XCTAssertTrue(orphan.evidence.contains("disk"), orphan.evidence)
    }

    func testSoftCausesAreListedButNotRanked() {
        let d = SlowdownDiagnosis.diagnose(incident(), system: incidentSystem, me: 99_999)
        let app = d.also.first { $0.kind == .heavyApp }
        XCTAssertEqual(app?.name, "Douyin AR")
        XCTAssertEqual(app?.action, .quitApp)
        XCTAssertEqual(app?.freesKB, 2 * gb + 10 * 100 * mb)
        let sessions = d.also.first { $0.kind == .agentSessions }
        XCTAssertEqual(sessions?.action, .review)
        XCTAssertEqual(sessions?.sessions?.count, 17)
        // Each session's own codegraph is normal: no session is a leaky parent, none of them an orphan.
        XCTAssertFalse((d.culprits + d.also).contains { $0.kind == .leakyParent && $0.name == "Claude Code" })
    }

    func testSystemProcessesAndThermoAreNeverNamed() {
        var ps = incident()
        ps.append(.init(pid: 4242, ppid: 1, name: "Thermo", executable: "/Applications/Thermo.app/Contents/MacOS/Thermo",
                        cpu: 200, cpuLifetime: 200, footprintKB: 8 * gb, elapsed: 100_000))
        let d = SlowdownDiagnosis.diagnose(ps, system: incidentSystem, me: 4242)
        let named = Set((d.culprits + d.also).flatMap(\.pids))
        for pid: Int32 in [1, 150, 151, 152, 4242] { XCTAssertFalse(named.contains(pid), "PID \(pid) must not be named") }
    }

    func testRunawayNeedsSustainedLoad() {
        let sys = SlowdownSystem(memoryBytes: 16 << 30, swapUsed: 0, swapTotal: 0, pressure: .normal, load1: 3, cores: 10)
        let shell = SlowdownProcess(pid: 500, ppid: 1, name: "zsh", executable: "/bin/zsh", elapsed: 9000)
        let burst = SlowdownProcess(pid: 501, ppid: 500, name: "swift-build", executable: "/usr/local/bin/swift-build",
                                    cpu: 300, cpuLifetime: 20, footprintKB: 500 * mb, elapsed: 40)
        XCTAssertTrue(SlowdownDiagnosis.diagnose([shell, burst], system: sys, me: 1).culprits.isEmpty)
        var watched = burst
        watched.busyFor = 5 * 60
        let d = SlowdownDiagnosis.diagnose([shell, watched], system: sys, me: 1)
        XCTAssertEqual(d.culprits.first?.kind, .runaway)
        XCTAssertEqual(d.culprits.first?.pids, [501])
    }

    func testQuietMacHasNoCulprits() {
        let sys = SlowdownSystem(memoryBytes: 16 << 30, swapUsed: 1 << 30, swapTotal: 2 << 30, pressure: .normal, load1: 2, cores: 10)
        let editor = SlowdownProcess(pid: 700, ppid: 1, name: "Xcode", executable: "/Applications/Xcode.app/Contents/MacOS/Xcode",
                                     cpu: 10, footprintKB: 3 * gb, elapsed: 50_000)
        let d = SlowdownDiagnosis.diagnose([editor], system: sys, me: 1)
        XCTAssertTrue(d.culprits.isEmpty)
        XCTAssertFalse(d.isReal)
        XCTAssertEqual(d.headline, tr("Nothing is slowing this Mac down right now."))
    }

    func testOnlyOwnCommandLineProcessesAreEndable() {
        let ps = Dictionary(incident().map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertTrue(SlowdownFix.endable(ps[51234]!, me: 1))
        XCTAssertTrue(SlowdownFix.endable(ps[6217]!, me: 1))
        XCTAssertFalse(SlowdownFix.endable(ps[150]!, me: 1), "WindowServer")
        XCTAssertFalse(SlowdownFix.endable(ps[152]!, me: 1), "system binary run as the user")
        XCTAssertFalse(SlowdownFix.endable(ps[96677]!, me: 1), "apps quit, they are not killed")
        XCTAssertFalse(SlowdownFix.endable(ps[39123]!, me: 1), "agent sessions hold conversations")
        XCTAssertFalse(SlowdownFix.endable(ps[6217]!, me: 6217), "Thermo itself")
    }

    func testEndRefusesAndRecordsNothingForProtectedProcess() {
        let ps = incident()
        let window = ps.first { $0.pid == 150 }!
        XCTAssertEqual(SlowdownFix.end(window, identity: nil, record: false).outcome, .refused)
    }

    func testEndStopsATestProcessAndReportsIt() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["600"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let pid = child.processIdentifier
        guard let identity = ProcessTable.identity(pid) else { return XCTFail("identity unreadable") }
        // /bin is a system path, so describe it as a user tool for the test; identity still guards the PID.
        let p = SlowdownProcess(pid: pid, ppid: getpid(), name: "sleep", executable: "/tmp/fixture/sleep", footprintKB: 1024)
        let r = SlowdownFix.end(p, identity: identity, grace: 2, record: false)
        XCTAssertEqual(r.outcome, .stopped)
        child.waitUntilExit()
        XCTAssertFalse(child.isRunning)
        // The PID is gone now: a second attempt must not send anything.
        XCTAssertEqual(SlowdownFix.end(p, identity: identity, grace: 1, record: false).outcome, .changed)
    }

    func testStrainLevels() {
        XCTAssertEqual(incidentSystem.memoryStrain, .exhausted)
        XCTAssertEqual(SlowdownSystem(memoryBytes: 16 << 30, swapUsed: 9 << 30, swapTotal: 20 << 30, pressure: .normal, load1: 1, cores: 10).memoryStrain, .tight)
        XCTAssertEqual(SlowdownSystem(memoryBytes: 16 << 30, swapUsed: 2 << 30, swapTotal: 3 << 30, pressure: .normal, load1: 1, cores: 10).memoryStrain, .none)
        XCTAssertEqual(incidentSystem.cpuStrain, .exhausted, "load 30 on 10 cores")
    }

    func testIncidentNotifiesOncePerReason() {
        let d = SlowdownDiagnosis.diagnose(incident(), system: incidentSystem, me: 99_999)
        var alerts = SlowdownAlerts()
        let now = Date()
        let first = alerts.evaluate(d, now: now)
        let keys = Set(first.map(\.key))
        XCTAssertTrue(keys.contains("swap-exhausted"), "swap nearly full alerts even when it is no longer growing")
        XCTAssertTrue(keys.contains("runaway:codegraph MCP server"))
        XCTAssertTrue(keys.contains { $0.hasPrefix("stuck:") })
        XCTAssertTrue(keys.contains("leak:codex app-server"))
        XCTAssertTrue(first.first { $0.key == "swap-exhausted" }?.body.contains("Frees about") == true)
        XCTAssertTrue(alerts.evaluate(d, now: now.addingTimeInterval(600)).isEmpty, "throttled")
        XCTAssertEqual(alerts.evaluate(d, now: now.addingTimeInterval(3700)).count, first.count)
    }

    func testQuietMacDoesNotNotify() {
        let sys = SlowdownSystem(memoryBytes: 16 << 30, swapUsed: 0, swapTotal: 0, pressure: .normal, load1: 1, cores: 10)
        var alerts = SlowdownAlerts()
        XCTAssertTrue(alerts.evaluate(SlowdownDiagnosis.diagnose([], system: sys, me: 1)).isEmpty)
        // A stuck agent tool is still listed, but with memory to spare it is not worth a notification.
        let d = SlowdownDiagnosis.diagnose(incident().filter { $0.pid != 6217 }, system: sys, me: 99_999)
        XCTAssertTrue(d.culprits.contains { $0.kind == .stuck })
        XCTAssertFalse(alerts.evaluate(d).contains { $0.key.hasPrefix("stuck:") })
    }

    func testIdleServicesPeopleStartedAreNotStuck() {
        // An idle VM inside an app bundle, and a dev database started from a terminal: big and quiet on purpose.
        let vm = SlowdownProcess(pid: 800, ppid: 1, name: "qemu-system-aarch64", executable: "/Applications/OrbStack.app/Contents/Frameworks/OrbStack Helper.app/Contents/MacOS/qemu-system-aarch64",
                                 cpu: 0.5, footprintKB: 6 * gb, elapsed: 40 * 3600)
        let shell = SlowdownProcess(pid: 801, ppid: 2085, name: "zsh", executable: "/bin/zsh", elapsed: 90_000)
        let postgres = SlowdownProcess(pid: 802, ppid: 801, name: "postgres", executable: "/opt/homebrew/bin/postgres",
                                       cpu: 0.2, footprintKB: 2 * gb, elapsed: 30 * 3600)
        let d = SlowdownDiagnosis.diagnose([vm, shell, postgres], system: incidentSystem, me: 1)
        XCTAssertFalse((d.culprits + d.also).contains { $0.kind == .stuck || $0.kind == .orphan }, d.culprits.map(\.name).joined(separator: ","))
        XCTAssertFalse(SlowdownFix.endable(vm, me: 1))
        XCTAssertEqual(SlowdownDiagnosis.diagnose(incident(), system: incidentSystem, me: 99_999).culprits.first { $0.kind == .orphan }?.program, "codegraph")
    }
}
