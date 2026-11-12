import AgentCore
import ThermoL10n
import XCTest
@testable import CleanKit

final class MemoryReliefTests: XCTestCase {
    func testRealDisposableProcessesAreRecheckedBeforeEnding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("com.example.thermo-relief-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("worker")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: binary)
        let signer = Process(); signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", binary.path]
        try signer.run(); signer.waitUntilExit()
        XCTAssertEqual(signer.terminationStatus, 0)
        func start() throws -> Process {
            let process = Process(); process.executableURL = binary; process.arguments = ["60"]
            try process.run(); return process
        }
        let selected = try start(), changed = try start()
        defer {
            for process in [selected, changed] {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }
        }
        let first = try XCTUnwrap(ProcessTable.identity(selected.processIdentifier))
        let second = try XCTUnwrap(ProcessTable.identity(changed.processIdentifier))
        let fresh = diagnosis([culprit("test worker", kind: .orphan, action: .end, pids: [first.pid], identities: [first])])
        let targets = MemoryRelief.targets(confirmed: [first, second], fresh: fresh)
        XCTAssertEqual(targets, [first])
        let sampled = SlowdownSampler().sample().filter { $0.pid == first.pid }
        XCTAssertEqual(sampled.count, 1)
        let outcome = MemoryRelief.end(targets, skipped: 1, live: sampled, journalHome: directory.path)
        XCTAssertEqual(outcome.ended, 1)
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertTrue(changed.isRunning)
        XCTAssertNil(ProcessTable.identity(first.pid))
    }

    func testSystemAgentAndThermoAreNeverEndable() {
        XCTAssertFalse(SlowdownFix.endable(.init(pid: getpid(), ppid: 1, name: "Thermo")))
        XCTAssertFalse(SlowdownFix.endable(.init(pid: 12345, ppid: 1, uid: 0, name: "launchd", executable: "/sbin/launchd")))
        XCTAssertFalse(SlowdownFix.endable(.init(pid: 12345, ppid: 1, name: "claude", executable: "/tmp/claude", argv: ["claude"])))
        XCTAssertFalse(SlowdownFix.endable(.init(pid: 12345, ppid: 1, name: "codex", executable: "/tmp/codex", argv: ["codex"])))
    }

    func identity(_ pid: Int32, started: TimeInterval = 1_000) -> ProcessIdentity {
        ProcessIdentity(pid: pid, uid: 501, started: Date(timeIntervalSince1970: started), executable: "/opt/homebrew/bin/node")
    }

    func culprit(_ name: String, kind: SlowdownCulprit.Kind, action: SlowdownCulprit.Action, pids: [Int32], identities: [ProcessIdentity]? = nil,
                 app: String? = nil, frees: Int = 800_000) -> SlowdownCulprit {
        SlowdownCulprit(kind: kind, action: action, name: name, launcher: nil, project: nil, pids: pids, identities: identities,
                        app: app, cpu: 0, memoryKB: frees, freesKB: frees, children: nil, elapsed: nil,
                        evidence: "", guidance: "", command: nil, sessions: nil, score: 1)
    }

    func diagnosis(_ culprits: [SlowdownCulprit], also: [SlowdownCulprit] = []) -> SlowdownDiagnosis {
        let system = SlowdownSystem(memoryBytes: 16 << 30, swapUsed: 21 << 30, swapTotal: 22 << 30, pressure: .warning, load1: 4, cores: 10)
        return SlowdownDiagnosis(sampled: Date(), system: system, memoryStrain: .tight, cpuStrain: .none, headline: "Memory is tight.",
                                 culprits: culprits, also: also)
    }

    func testOnlyIdleAndLeftoverProcessesGoBehindTheOneButton() {
        let plan = MemoryReliefPlan(diagnosis([
            culprit("Google Chrome", kind: .heavyApp, action: .quitApp, pids: [10], app: "/Applications/Google Chrome.app", frees: 6_000_000),
            culprit("codegraph MCP server", kind: .idleMCP, action: .end, pids: [20, 21, 22], identities: [identity(20), identity(21)], frees: 900_000),
            culprit("cargo", kind: .runaway, action: .end, pids: [30], identities: [identity(30)], frees: 3_000_000),
        ], also: [
            culprit("AI agent sessions", kind: .agentSessions, action: .review, pids: [40, 41], frees: 9_000_000),
            culprit("rea MCP server", kind: .idleMCP, action: .review, pids: [50], frees: 500_000),
            culprit("node", kind: .orphan, action: .end, pids: [60], identities: [identity(60)], frees: 300_000),
            culprit("tiny", kind: .orphan, action: .end, pids: [70], identities: [identity(70)], frees: 10_000),
            culprit("no identity", kind: .stuck, action: .end, pids: [80], identities: nil, frees: 700_000),
        ]))
        // Safe first, then apps, then the person's call; biggest first inside each.
        XCTAssertEqual(plan.steps.map(\.culprit.name),
                       ["codegraph MCP server", "node", "Google Chrome", "AI agent sessions", "cargo", "no identity", "rea MCP server"])
        XCTAssertEqual(plan.steps.map(\.tier), [.safe, .safe, .ask, .manual, .manual, .manual, .manual])
        // A busy process may be the person's build, and agent sessions are never ended: neither is behind the button.
        XCTAssertEqual(plan.safeIdentities.map(\.pid), [20, 21, 60])
        XCTAssertEqual(plan.safeKB, 1_200_000)
    }

    func testAStepIsListedOnceAndAnAppWithoutABundleIsNotQuit() {
        let mcp = culprit("codegraph MCP server", kind: .idleMCP, action: .end, pids: [20], identities: [identity(20)])
        let plan = MemoryReliefPlan(diagnosis([mcp, culprit("helper", kind: .heavyApp, action: .quitApp, pids: [10], app: nil)], also: [mcp]))
        XCTAssertEqual(plan.steps.map(\.tier), [.safe, .manual])
    }

    func testOnlyWhatAFreshDiagnosisStillNamesIsEnded() {
        let confirmed = [identity(20), identity(21), identity(60)]
        let fresh = diagnosis([
            // 21's session woke up, so it is no longer among the copies to end; 22 is new and was never confirmed.
            culprit("codegraph MCP server", kind: .idleMCP, action: .end, pids: [20, 22], identities: [identity(20), identity(22)]),
            // PID 60 was reused by another process: same number, different start time.
            culprit("node", kind: .orphan, action: .end, pids: [60], identities: [identity(60, started: 2_000)]),
        ])
        XCTAssertEqual(MemoryRelief.targets(confirmed: confirmed, fresh: fresh).map(\.pid), [20])
        XCTAssertTrue(MemoryRelief.targets(confirmed: confirmed, fresh: diagnosis([])).isEmpty)
    }

    func testSummarySaysWhatWasEndedAndWhatWasLeftAlone() {
        L10n.override = .english
        defer { L10n.override = nil }
        func result(_ pid: Int32, _ outcome: SlowdownFix.Outcome, freed: Int) -> SlowdownFix.Result {
            SlowdownFix.Result(pid: pid, name: "codegraph", outcome: outcome, freedKB: freed, swapBefore: nil, swapAfter: nil, loadBefore: 0, loadAfter: nil)
        }
        let outcome = MemoryRelief.Outcome(results: [result(20, .stopped, freed: 512 * 1024), result(21, .killed, freed: 512 * 1024), result(22, .changed, freed: 0)],
                                           skipped: 2, swapBefore: 21 << 30, swapAfter: 20 << 30)
        XCTAssertEqual(outcome.ended, 2)
        XCTAssertTrue(outcome.summary.contains("Ended 2 of 3 processes"), outcome.summary)
        XCTAssertTrue(outcome.summary.contains("2 were left alone"), outcome.summary)
        XCTAssertTrue(outcome.summary.contains("Swap used"), outcome.summary)
        let none = MemoryRelief.Outcome(results: [], skipped: 3, swapBefore: 1, swapAfter: 1)
        XCTAssertTrue(none.summary.hasPrefix("Nothing was ended"), none.summary)
        XCTAssertFalse(none.summary.contains("Swap used"), none.summary)
    }
}
