import XCTest
@testable import ThermoApp

final class AgentAccessCommandTests: XCTestCase {
    func testLargeErrorOutputDoesNotBlockInstallerRunner() {
        let output = AgentAccess.run("/bin/sh", ["-c", "i=0; while [ $i -lt 10000 ]; do echo fixture-error >&2; i=$((i+1)); done; printf finished"], timeout: 3)
        XCTAssertTrue(output?.hasSuffix("finished") == true)
    }

    func testTimeoutDoesNotLeaveRunnerWaitingForIgnoredTerm() {
        let started = Date()
        let output = AgentAccess.run("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 5"], timeout: 0.1)
        XCTAssertNil(output)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testFailureIsNotTreatedAsSuccessfulInstall() {
        XCTAssertNil(AgentAccess.run("/bin/sh", ["-c", "printf fixture-error >&2; exit 1"], timeout: 2))
    }
}
