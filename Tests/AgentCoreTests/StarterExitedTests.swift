import Foundation
import XCTest
@testable import AgentCore

/// "Its starter has exited": parent 1 and a process group whose leader is gone.
final class StarterExitedTests: XCTestCase {
    func testOnlyAnAdoptedMemberOfADeadGroupCounts() {
        let dead: (pid_t) -> Bool = { _ in false }, alive: (pid_t) -> Bool = { _ in true }
        XCTAssertTrue(ProcessTable.starterExited(pid: 50, ppid: 1, pgid: 40, leaderAlive: dead))
        // Its starter is still there.
        XCTAssertFalse(ProcessTable.starterExited(pid: 50, ppid: 30, pgid: 40, leaderAlive: dead))
        // A launchd job or a detached daemon leads its own group.
        XCTAssertFalse(ProcessTable.starterExited(pid: 50, ppid: 1, pgid: 50, leaderAlive: dead))
        // The group still has its leader: a shell job put in the background, for example.
        XCTAssertFalse(ProcessTable.starterExited(pid: 50, ppid: 1, pgid: 40, leaderAlive: alive))
        XCTAssertFalse(ProcessTable.starterExited(pid: 50, ppid: 1, pgid: 0, leaderAlive: dead))
    }

    /// Real processes: one left behind by a starter that led its own group and exited, and one that
    /// detached on purpose into a group of its own.
    func testLiveReadSeparatesLeftBehindFromDetached() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("com.example.thermo-starter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func spawn(_ script: String, pidFile: String) throws -> pid_t {
            let file = directory.appendingPathComponent(pidFile)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = ["-e", script, file.path]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let text = try? String(contentsOf: file, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    addTeardownBlock { kill(pid, SIGKILL) }
                    return pid
                }
                usleep(50_000)
            }
            throw XCTSkip("the helper did not report its child")
        }
        // The starter leads a new group, starts a child, records it and exits.
        let left = try spawn(#"setpgrp(0,0); my $c = fork(); if ($c == 0) { exec "/bin/sleep", "120" } open(my $f, ">", $ARGV[0]); print $f $c; close $f;"#,
                             pidFile: "left")
        // The child moves into its own group before running.
        let detached = try spawn(#"my $c = fork(); if ($c == 0) { setpgrp(0,0); exec "/bin/sleep", "120" } open(my $f, ">", $ARGV[0]); print $f $c; close $f;"#,
                                 pidFile: "detached")
        // launchd adopts them once the starter is reaped.
        var entries: [pid_t: AgentProcess] = [:]
        let deadline = Date().addingTimeInterval(5)
        repeat {
            entries = Dictionary(ProcessTable.current(.init(cpu: false)).entries.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
            if entries[left]?.ppid == 1, entries[detached]?.ppid == 1 { break }
            usleep(100_000)
        } while Date() < deadline
        XCTAssertEqual(entries[left]?.starterExited, true)
        XCTAssertEqual(entries[detached]?.starterExited, false)
        XCTAssertEqual(entries[getpid()]?.starterExited, false)
    }
}
