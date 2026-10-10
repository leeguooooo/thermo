import XCTest
import AgentCore
import Darwin
@testable import ThermoApp

final class ProcessActionTests: XCTestCase {
    func testProcessActionRejectsReusedPIDAndChangedExecutable() {
        let original = ProcessIdentity(pid: 42, uid: 501, started: Date(timeIntervalSince1970: 100), executable: "/fixture/tool")
        XCTAssertTrue(SystemPulse.canSignal(original, current: original, uid: 501, me: 99))
        var replacement = original
        replacement.started = Date(timeIntervalSince1970: 200)
        XCTAssertFalse(SystemPulse.canSignal(original, current: replacement, uid: 501, me: 99))
        replacement = original
        replacement.executable = "/fixture/other"
        XCTAssertFalse(SystemPulse.canSignal(original, current: replacement, uid: 501, me: 99))
        XCTAssertFalse(SystemPulse.canSignal(original, current: nil, uid: 501, me: 99))
    }

    func testProcessActionRejectsOtherUsersAndObserver() {
        let original = ProcessIdentity(pid: 42, uid: 501, started: Date(timeIntervalSince1970: 100), executable: "/fixture/tool")
        XCTAssertFalse(SystemPulse.canSignal(original, current: original, uid: 502, me: 99))
        XCTAssertFalse(SystemPulse.canSignal(original, current: original, uid: 501, me: 42))
        var system = original
        system.pid = 1
        XCTAssertFalse(SystemPulse.canSignal(system, current: system, uid: 501, me: 99))
    }

    func testCurrentProcessIdentityIsStable() throws {
        let first = try XCTUnwrap(ProcessTable.identity(getpid()))
        let next = try XCTUnwrap(ProcessTable.identity(getpid()))
        XCTAssertEqual(first, next)
        XCTAssertEqual(first.uid, getuid())
        XCTAssertFalse(first.executable.isEmpty)
    }
}
