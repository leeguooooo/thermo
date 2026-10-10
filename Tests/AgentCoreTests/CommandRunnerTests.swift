import XCTest
import AgentCore

final class CommandRunnerTests: XCTestCase {
    func testLargeCombinedOutputIsDrainedAndBounded() {
        let script = "i=0; while [ $i -lt 2000 ]; do echo fixture-output; echo fixture-error >&2; i=$((i+1)); done"
        let result = CommandRunner.run("/bin/sh", arguments: ["-c", script], timeout: 3, outputLimit: 256)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.utf8.count, 256)
        XCTAssertFalse(result.timedOut)
        XCTAssertTrue(result.truncated)
    }

    func testTimeoutReapsAChildThatIgnoresTerm() {
        let started = Date()
        let result = CommandRunner.run("/bin/sh", arguments: ["-c", "trap '' TERM; exec /bin/sleep 5"], timeout: 0.1)
        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testCancellationStopsItsOwnChild() {
        let deadline = Date().addingTimeInterval(0.05)
        let result = CommandRunner.run("/bin/sleep", arguments: ["5"], timeout: 3, cancelled: { Date() >= deadline })
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.timedOut)
    }
}
