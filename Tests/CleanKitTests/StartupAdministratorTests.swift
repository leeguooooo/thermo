@testable import AgentCore
@testable import CleanKit
import Darwin
import Foundation
import XCTest

final class StartupAdministratorTests: XCTestCase {
    var home = "", root = "", stateFile = "", callsFile = "", tool = ""
    var location: StartupItems.Location { .init(path: root, scope: .systemDaemon, owner: getuid()) }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-admin-'-$()-" + UUID().uuidString).resolvingSymlinksInPath().path
        root = home + "/LaunchDaemons"; stateFile = home + "/state"; callsFile = home + "/calls"; tool = home + "/launchctl"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let plist: [String: Any] = ["Label": "test.fixture", "Program": "/bin/echo"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: root + "/fixture.plist"))
        try writeState("enabled")
        let body = """
        #!/bin/sh
        set -eu
        case "$1" in
        print-disabled)
            [ "$2" = system ]
            /usr/bin/printf 'disabled services = {\\n"test.fixture" => %s\\n}\\n' "$(/bin/cat \(quote(stateFile)))"
            ;;
        enable|disable)
            [ "$2" = system/test.fixture ]
            /usr/bin/printf '%s\\n' "$1" >> \(quote(callsFile))
            if [ "$1" = enable ]; then /usr/bin/printf enabled > \(quote(stateFile)); else /usr/bin/printf disabled > \(quote(stateFile)); fi
            ;;
        *) exit 7 ;;
        esac
        """
        try body.write(toFile: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
    func writeState(_ value: String) throws { try value.write(toFile: stateFile, atomically: true, encoding: .utf8) }
    func run(_ args: [String]) -> CommandRunner.Result { CommandRunner.run(tool, arguments: args, timeout: 3) }
    func reviewed() throws -> StartupItem { try XCTUnwrap(StartupItems.scan(home: home, locations: [location], runner: run).items.first) }

    /// Exercise the generated shell against real fixture files and a launchctl substitute.
    /// Only uid checks and launchctl are substituted; stat, SHA-256 and state parsing run normally.
    func execute(_ script: String) -> CommandRunner.Result {
        let fixture = script.replacingOccurrences(of: "/bin/launchctl", with: quote(tool))
            .replacingOccurrences(of: "/usr/bin/id -u", with: "/usr/bin/printf 0")
            .replacingOccurrences(of: "/usr/bin/stat -f '%u' \"$path\"", with: "/usr/bin/printf 0")
        return CommandRunner.run("/bin/sh", arguments: ["-c", fixture], timeout: 5)
    }

    func testAdministratorTransactionRunsGuardsMutatesOnlySystemOverrideAndReadsBack() throws {
        let item = try reviewed(), original = try Data(contentsOf: URL(fileURLWithPath: item.path))
        let after = try StartupItems.setEnabled(false, item: item, home: home, locations: [location], runner: run, administrator: execute)
        XCTAssertEqual(after.enabled, false)
        XCTAssertEqual(try String(contentsOfFile: callsFile), "disable\n")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: item.path)), original)
        XCTAssertEqual(OperationJournal.read(home: home).first?.outcome, "succeeded")
        let restored = try StartupItems.setEnabled(true, item: after, home: home, locations: [location], runner: run, administrator: execute)
        XCTAssertEqual(restored.enabled, true)
        XCTAssertEqual(try String(contentsOfFile: callsFile), "disable\nenable\n")
    }

    func testConfigurationChangedWhileAuthorizationWaitedStopsBeforeMutation() throws {
        let item = try reviewed()
        XCTAssertThrowsError(try StartupItems.setEnabled(false, item: item, home: home, locations: [location], runner: run, administrator: { script in
            try! Data("changed during approval".utf8).write(to: URL(fileURLWithPath: item.path))
            return self.execute(script)
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: callsFile))
        XCTAssertEqual(try String(contentsOfFile: stateFile), "enabled")
    }

    func testStateChangedOrMalformedDuringAuthorizationStopsBeforeMutation() throws {
        for value in ["disabled", "maybe"] {
            try writeState("enabled")
            let item = try reviewed()
            XCTAssertThrowsError(try StartupItems.setEnabled(false, item: item, home: home, locations: [location], runner: run, administrator: { script in
                try! self.writeState(value)
                return self.execute(script)
            }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: callsFile))
        }
    }

    func testCancelledAuthorizationAndMissingReceiptNeverReportSuccess() throws {
        let item = try reviewed()
        for response in [CommandRunner.Result(status: -128, output: "cancelled", timedOut: false, cancelled: true),
                         .init(status: 0, output: "", timedOut: false, cancelled: false)] {
            XCTAssertThrowsError(try StartupItems.setEnabled(false, item: item, home: home, locations: [location], runner: run, administrator: { _ in response }))
            XCTAssertFalse(FileManager.default.fileExists(atPath: callsFile))
            XCTAssertEqual(OperationJournal.read(home: home).first?.outcome, "failed")
        }
    }

    func testInvalidScopeOrFingerprintCannotGenerateAPrivilegedScript() throws {
        var item = try reviewed()
        item.scope = .userAgent
        XCTAssertThrowsError(try StartupItems.administratorScript(false, item: item, defaultEnabled: true, root: root))
        item.scope = .systemDaemon; item.fingerprint = "malformed; touch /tmp/not-allowed"
        XCTAssertThrowsError(try StartupItems.administratorScript(false, item: item, defaultEnabled: true, root: root))
    }

    func testSymlinkOrWritableConfigurationDuringApprovalNeverMutatesState() throws {
        let item = try reviewed()
        let backup = item.path + ".saved"
        try FileManager.default.copyItem(atPath: item.path, toPath: backup)
        XCTAssertThrowsError(try StartupItems.setEnabled(false, item: item, home: home, locations: [location], runner: run, administrator: { script in
            try! FileManager.default.removeItem(atPath: item.path)
            try! FileManager.default.createSymbolicLink(atPath: item.path, withDestinationPath: backup)
            return self.execute(script)
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: callsFile))
        try FileManager.default.removeItem(atPath: item.path)
        try FileManager.default.moveItem(atPath: backup, toPath: item.path)
        let fresh = try reviewed()
        XCTAssertThrowsError(try StartupItems.setEnabled(false, item: fresh, home: home, locations: [location], runner: run, administrator: { script in
            try! FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: fresh.path)
            return self.execute(script)
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: callsFile))
    }
}
