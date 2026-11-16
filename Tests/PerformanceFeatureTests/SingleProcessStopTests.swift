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
        let (process, identity) = try start(shell, ["-c", "trap '' TERM; while :; do /bin/sleep 1; done"])
        usleep(300_000) // let the trap install
        XCTAssertEqual(SystemPulse.perform(.init(identity: identity, name: "stubborn"), grace: 1), .stillRunning)
        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(SystemPulse.perform(.init(identity: identity, name: "stubborn", force: true), grace: 5), .killed)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, SIGKILL)
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
