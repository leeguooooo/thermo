import XCTest
@testable import CleanKit

final class ScanCommandTests: XCTestCase {
    func testCancelledReadCommandStopsWithoutWaitingForTimeout() {
        let token = ScanCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { token.cancel() }
        let start = Date()
        let output = Shell.run("exec /bin/sleep 10", timeout: 20, cancellation: token)
        XCTAssertNil(output)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testDirectCommandHonorsCancellationAndKeepsNormalExitStatus() {
        let token = ScanCancellation(); token.cancel()
        let result = Shell.exec(["/bin/sleep", "10"], timeout: 20, cancellation: token)
        XCTAssertEqual(result.0, -1)
        XCTAssertEqual(result.1, "cancelled")
        XCTAssertEqual(Shell.exec(["/bin/sh", "-c", "exit 7"], timeout: 2).0, 7)
    }
    func testTruncatedOutputIsNeverTreatedAsACompleteScan() {
        let result = Shell.run("exec /usr/bin/awk 'BEGIN { for (i=0;i<150000;i++) print \"synthetic-fixture-output\" }'", timeout: 5)
        XCTAssertNil(result)
    }
    func testGitFailureInWorktreeCannotBecomeCleanViaHeadPipeline() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let wt = home + "/repo/.worktrees/broken"
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        try Data("gitdir: /missing/thermo-git-fixture".utf8).write(to: URL(fileURLWithPath: wt + "/.git"))
        try Data(repeating: 65, count: 5000).write(to: URL(fileURLWithPath: wt + "/file"))
        var options = ScanOptions(); options.home = home
        let ctx = ScanContext(options: options, now: Date(), processes: ProcessTable(entries: []), agentDirs: [], liveClaudeSessions: [])
        let item = try XCTUnwrap(Projects.worktreeItem(wt, repo: home + "/repo", repoName: "repo", ctx: ctx))
        XCTAssertNotNil(item.blocked)
        XCTAssertFalse(item.cleanable)
    }
}
