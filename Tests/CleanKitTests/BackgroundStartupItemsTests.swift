import XCTest
@testable import AgentCore
import Darwin
@testable import CleanKit

final class BackgroundStartupItemsTests: XCTestCase {
    func testControlCharactersInAppMetadataCannotBecomeTerminalInstructions() {
        let text = dump().replacingOccurrences(of: "Name: Fixture", with: "Name: \u{1B}[2JFixture")
        let report = BackgroundStartupItems.parse(output(text), uid: 501)
        XCTAssertEqual(report.status, .partial); XCTAssertTrue(report.items.isEmpty)
    }
    func testModernOSDoesNotStartAnUnprivilegedAuthorizationWait() {
        let report = BackgroundStartupItems.readWithoutApproval(majorVersion: 14, query: { XCTFail("must require explicit approval before querying"); return self.output("") })
        XCTAssertEqual(report.status, .requiresAuthorization)
        let older = BackgroundStartupItems.readWithoutApproval(majorVersion: 13, query: { self.output(self.dump(uid: Int(getuid()))) })
        XCTAssertEqual(older.status, .available)
    }
    func output(_ text: String, status: Int32 = 0, timedOut: Bool = false, truncated: Bool = false) -> CommandRunner.Result {
        .init(status: status, output: text, timedOut: timedOut, cancelled: false, truncated: truncated)
    }
    func dump(uid: Int = 501, uuid: String = "00000000-0000-0000-0000-000000000001", disposition: String = "enabled, disallowed", extra: String = "") -> String {
        """
        Records for UID \(uid) : fixture
        Items:
        #1:
          UUID: \(uuid)
          Name: Fixture
          Identifier: com.example.fixture
          Type: login item (0x2)
          Disposition: [\(disposition)] (0)
          URL: file:///Applications/Fixture%20App.app
          Executable Path: /Applications/Fixture App.app/Contents/MacOS/Fixture
        \(extra)
        """
    }
    func testRegistrationAndApprovalRemainSeparateFacts() {
        let report = BackgroundStartupItems.parse(output(dump()), uid: 501)
        XCTAssertEqual(report.status, .available)
        XCTAssertEqual(report.items.first?.requested, true)
        XCTAssertEqual(report.items.first?.allowed, false)
        XCTAssertEqual(report.items.first?.path, "/Applications/Fixture App.app")
    }
    func testOnlyCurrentUserAndSystemRecordsAreDisplayed() {
        let report = BackgroundStartupItems.parse(output(dump(uid: 0) + "\n" + dump(uid: 501) + "\n" + dump(uid: 999)), uid: 501)
        XCTAssertEqual(Set(report.items.map(\.uid)), [0, 501])
        XCTAssertEqual(report.items.count, 2, "same UUID in different user scopes has a different identity")
    }
    func testUnknownOrContradictoryDispositionDoesNotBecomeDisabled() {
        for token in ["visible", "enabled, disabled, allowed"] {
            let report = BackgroundStartupItems.parse(output(dump(disposition: token)), uid: 501)
            XCTAssertEqual(report.status, .partial)
            XCTAssertNil(report.items.first?.requested)
        }
    }
    func testMalformedAndUnrecognizedOutputIsNotAnEmptyAvailableInventory() {
        for text in ["", "tool failed", "Records for UID 501 : fixture\nName: Missing boundary"] {
            XCTAssertEqual(BackgroundStartupItems.parse(output(text), uid: 501).status, .unavailable)
        }
        let empty = BackgroundStartupItems.parse(output("Records for UID 501 : fixture\nItems:"), uid: 501)
        XCTAssertEqual(empty.status, .available); XCTAssertTrue(empty.items.isEmpty)
        XCTAssertEqual(BackgroundStartupItems.parse(output(dump(uuid: "invalid")), uid: 501).status, .partial)
    }
    func testTimeoutAndTruncationDiscardAnApparentlyValidPartialDump() {
        for result in [output(dump(), status: 1), output(dump(), timedOut: true), output(dump(), truncated: true)] {
            let report = BackgroundStartupItems.parse(result, uid: 501)
            XCTAssertEqual(report.status, .unavailable); XCTAssertTrue(report.items.isEmpty)
        }
    }
    func testDuplicateFieldsAndDuplicateIdentitiesAreNotSilentlyChosen() {
        XCTAssertTrue(BackgroundStartupItems.parse(output(dump(extra: "Name: Different")), uid: 501).items.isEmpty)
        let repeated = BackgroundStartupItems.parse(output(dump() + "\n" + dump()), uid: 501)
        XCTAssertEqual(repeated.status, .partial); XCTAssertTrue(repeated.items.isEmpty)
    }
    func testNonFileAndRemoteFileURLsAreNotLocalLaunchPaths() {
        for url in ["https://example.com/file", "file://remote-host/Applications/Fixture.app"] {
            let report = BackgroundStartupItems.parse(output(dump().replacingOccurrences(of: "file:///Applications/Fixture%20App.app", with: url)), uid: 501)
            XCTAssertNil(report.items.first?.path)
        }
    }
    func testAuthorizationUsesOnlyTheFixedReadProgramAndPreservesFailure() {
        let report = BackgroundStartupItems.readAuthorized(authorize: { script in
            XCTAssertTrue(script.contains("/usr/bin/sfltool dumpbtm")); XCTAssertFalse(script.contains("resetbtm"))
            XCTAssertFalse(script.contains("launchctl")); XCTAssertTrue(script.contains("stop_child"))
            return self.output("", status: 1)
        })
        XCTAssertEqual(report.status, .unavailable)
        XCTAssertEqual(BackgroundStartupReport.requiresAuthorization.status, .requiresAuthorization)
    }
    func testWatchdogScriptFinishesQuickQueriesWithoutWaitingForItsTimer() {
        let script = BackgroundStartupItems.authorizationScript
            .replacingOccurrences(of: "/usr/bin/id -u", with: "/usr/bin/printf 0")
            .replacingOccurrences(of: "/usr/bin/sfltool dumpbtm", with: "/bin/sleep 0.05")
        let start = Date()
        let result = CommandRunner.run("/bin/sh", arguments: ["-c", script], timeout: 3)
        XCTAssertEqual(result.status, 0, result.output); XCTAssertFalse(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
    func testWatchdogTerminatesOnlyItsOwnedSlowQuery() throws {
        let peer = Process(); peer.executableURL = URL(fileURLWithPath: "/bin/sleep"); peer.arguments = ["5"]
        try peer.run(); defer { if peer.isRunning { peer.terminate() }; peer.waitUntilExit() }
        let script = BackgroundStartupItems.authorizationScript
            .replacingOccurrences(of: "/usr/bin/id -u", with: "/usr/bin/printf 0")
            .replacingOccurrences(of: "/usr/bin/sfltool dumpbtm", with: #"/bin/sh -c 'trap "" TERM; exec /bin/sleep 5'"#)
            .replacingOccurrences(of: "/bin/sleep 30", with: "/bin/sleep 0.1")
            .replacingOccurrences(of: "/bin/sleep 2", with: "/bin/sleep 0.1")
        let result = CommandRunner.run("/bin/sh", arguments: ["-c", script], timeout: 3)
        XCTAssertNotEqual(result.status, 0); XCTAssertFalse(result.timedOut)
        XCTAssertTrue(peer.isRunning)
    }
}
