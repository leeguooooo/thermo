import Combine
import Foundation
import XCTest
@testable import CleanKit
@testable import PerformanceFeature

/// Ending one hand-picked process from the Memory page, against real disposable processes.
final class SingleProcessStopTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("com.example.thermo-stop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    /// A private copy, so the executable is neither a system path nor shared with anything else.
    private func binary(_ source: String, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: url)
        let signer = Process(); signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", url.path]
        signer.standardError = FileHandle.nullDevice
        try signer.run(); signer.waitUntilExit()
        XCTAssertEqual(signer.terminationStatus, 0)
        return url
    }
    private func start(_ url: URL, _ arguments: [String]) throws -> (Process, ProcessIdentity) {
        let process = Process(); process.executableURL = url; process.arguments = arguments
        try process.run()
        addTeardownBlock { if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit() }
        return (process, try XCTUnwrap(ProcessTable.identity(process.processIdentifier)))
    }

    func testOrdinaryProcessStopsAfterBeingAsked() throws {
        let (process, identity) = try start(try binary("/bin/sleep", named: "worker"), ["60"])
        let result = SystemPulse.perform(.init(identity: identity, name: "worker"), grace: 5)
        XCTAssertEqual(result, .stopped)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGTERM)
    }

    func testAgentSessionNeedsTheExplicitManualCapability() throws {
        let (process, identity) = try start(try binary("/bin/sleep", named: "claude"), ["60"])
        XCTAssertEqual(SystemPulse.perform(.init(identity: identity, name: "claude"), grace: 1), .protected)
        XCTAssertTrue(process.isRunning, "the default path must not signal an agent session")
        XCTAssertEqual(SystemPulse.perform(.init(identity: identity, name: "claude", agentSession: true), grace: 5), .stopped)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, SIGTERM)
    }

    func testProcessIgnoringTheRequestIsReportedThenForced() throws {
        let shell = try binary("/bin/dash", named: "stubborn")
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent("stubborn-ready-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: ready) }
        let (process, identity) = try start(shell, ["-c", "trap '' TERM; : > \"$0\"; while :; do /bin/sleep 1; done", ready.path])
        // Under a loaded machine the shell may not have installed the trap after a fixed delay; wait for it to say so.
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline { usleep(20_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "the shell never installed its TERM trap")
        XCTAssertEqual(SystemPulse.perform(.init(identity: identity, name: "stubborn"), grace: 1), .stillRunning)
        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(SystemPulse.perform(.init(identity: identity, name: "stubborn", force: true), grace: 5), .killed)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, SIGKILL)
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock(); private var performed = 0, recorded: [SystemPulse.SingleStopResult] = []
        func perform() { lock.lock(); performed += 1; lock.unlock() }
        func record(_ r: SystemPulse.SingleStopResult) { lock.lock(); recorded.append(r); lock.unlock() }
        var counts: (Int, [SystemPulse.SingleStopResult]) { lock.lock(); defer { lock.unlock() }; return (performed, recorded) }
    }
    private func fixture(force: Bool = false) -> SystemPulse.SingleStop {
        .init(identity: .init(pid: 4242, uid: getuid(), started: Date(timeIntervalSince1970: 100), executable: "/fixture/worker"),
              name: "worker", force: force, memoryKB: 2048)
    }
    /// Runs `end` with a stand-in for the signal and waits until the row is no longer marked busy.
    @MainActor private func run(_ pulse: SystemPulse, _ stop: SystemPulse.SingleStop, result: SystemPulse.SingleStopResult, calls: Calls) async {
        let finished = expectation(description: "end finished")
        var seenBusy = false
        let observation = pulse.$ending.sink { ending in
            if ending.contains(stop.identity.pid) { seenBusy = true } else if seenBusy { finished.fulfill(); seenBusy = false }
        }
        pulse.end(stop, grace: 0, perform: { _, _ in calls.perform(); return result }, record: { _, r in calls.record(r) })
        XCTAssertTrue(pulse.ending.contains(stop.identity.pid), "the row shows progress as soon as the action starts")
        await fulfillment(of: [finished], timeout: 10)
        observation.cancel()
    }

    @MainActor func testSwitchedOffFeatureSendsNothing() {
        let calls = Calls()
        let pulse = SystemPulse(actionsAllowed: { false })
        pulse.end(fixture(), perform: { _, _ in calls.perform(); return .stopped }, record: { _, r in calls.record(r) })
        XCTAssertTrue(pulse.ending.isEmpty)
        XCTAssertEqual(calls.counts.0, 0)
        XCTAssertNotNil(pulse.quitProblem, "a confirmed action that does nothing has to say why")
    }

    @MainActor func testStoppedProcessReportsWhatWasFreedAndIsRecorded() async {
        let calls = Calls(), pulse = SystemPulse()
        await run(pulse, fixture(), result: .stopped, calls: calls)
        XCTAssertEqual(calls.counts.0, 1); XCTAssertEqual(calls.counts.1, [.stopped])
        XCTAssertNil(pulse.unresponsive); XCTAssertNil(pulse.quitProblem)
        XCTAssertEqual(pulse.actionFeedback?.contains("4242"), true)
    }

    @MainActor func testUnresponsiveProcessOffersForceAndAFailedForceIsAProblem() async {
        let calls = Calls(), pulse = SystemPulse()
        await run(pulse, fixture(), result: .stillRunning, calls: calls)
        XCTAssertEqual(pulse.unresponsive, fixture())
        XCTAssertNil(pulse.actionFeedback)
        await run(pulse, fixture(force: true), result: .stillRunning, calls: calls)
        XCTAssertNil(pulse.unresponsive, "a new attempt clears the earlier offer")
        XCTAssertEqual(pulse.quitProblem?.contains("4242"), true)
        await run(pulse, fixture(), result: .protected, calls: calls)
        XCTAssertNotNil(pulse.quitProblem); XCTAssertNil(pulse.actionFeedback)
    }

    func testEndingAWholeProgramSkipsAgentsAndChangedIdentities() throws {
        let worker = try binary("/bin/sleep", named: "worker")
        let (first, a) = try start(worker, ["60"]), (second, b) = try start(worker, ["60"])
        let (agent, c) = try start(try binary("/bin/sleep", named: "claude"), ["60"])
        var stale = b; stale.started = b.started.addingTimeInterval(-60)
        // Even if an agent identity were handed in, this path has no capability to end it.
        let stop = SystemPulse.ProgramStop(id: "program:cmd:worker", name: "worker",
                                           rows: [.init(project: "~/a", identities: [a]), .init(project: "~/b", identities: [stale, c])])
        let result = SystemPulse.perform(stop, grace: 5)
        XCTAssertEqual(result, .init(ended: 1, stillRunning: 0, skipped: 2))
        first.waitUntilExit()
        XCTAssertEqual(first.terminationStatus, SIGTERM)
        XCTAssertTrue(second.isRunning); XCTAssertTrue(agent.isRunning)
    }

    func testReusedOrExitedPIDSendsNothing() throws {
        let (process, identity) = try start(try binary("/bin/sleep", named: "worker"), ["60"])
        var stale = identity; stale.started = identity.started.addingTimeInterval(-60)
        var signals = 0
        let result = SystemPulse.perform(.init(identity: stale, name: "worker", force: true), grace: 1) { _, _ in signals += 1; return true }
        XCTAssertEqual(result, .changed)
        XCTAssertEqual(signals, 0)
        XCTAssertTrue(process.isRunning)
    }
}
