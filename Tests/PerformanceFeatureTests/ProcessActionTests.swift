import XCTest
import AgentCore
import Darwin
@testable import PerformanceFeature

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
    func testUnchangedIdentityStillCannotAuthorizeAnAgentSystemOrThermoProcess() {
        for path in ["/opt/homebrew/bin/codex","/Users/fixture/.local/share/claude/versions/2.0.0",
                     "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
                     "/usr/libexec/fixture-service","/Library/PrivilegedHelperTools/thermo-helper",
                     "/Applications/Thermo.app/Contents/Extensions/Fixture.appex/Contents/MacOS/Fixture"] {
            let identity=ProcessIdentity(pid:42,uid:501,started:Date(timeIntervalSince1970:100),executable:path)
            XCTAssertFalse(SystemPulse.canSignal(identity,current:identity,uid:501,me:99),path)
        }
    }

}
