@testable import AgentCore
@testable import CleanKit
import Foundation
import XCTest

final class StartupItemsTests: XCTestCase {
    var home = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: home + "/Library/LaunchAgents", withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    @discardableResult func write(_ file: String = "fixture", label: String = "test.fixture", disabled: Bool = false) throws -> String {
        let path = home + "/Library/LaunchAgents/" + file + ".plist"
        let plist: [String: Any] = ["Label": label, "ProgramArguments": ["/bin/echo", "private argument"], "RunAtLoad": true, "Disabled": disabled]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: path))
        return path
    }
    func result(_ output: String = "", status: Int32 = 0) -> CommandRunner.Result {
        .init(status: status, output: output, timedOut: false, cancelled: false)
    }
    func state(_ value: String = "") -> CommandRunner.Result { result("disabled services = {\n" + value + "\n}\n") }

    func testOverridesAndDefaultDisabledState() throws {
        try write(disabled: true)
        let off = StartupItems.scan(home: home, runner: { _ in self.state() })
        XCTAssertEqual(off.items.first?.enabled, false)
        let on = StartupItems.scan(home: home, runner: { _ in self.state("\"test.fixture\" => enabled") })
        XCTAssertEqual(on.items.first?.enabled, true)
        XCTAssertEqual(on.items.first?.program, "/bin/echo")
        XCTAssertTrue(on.issues.isEmpty)
        XCTAssertEqual(try StartupItems.overrides(state("\"test.fixture\" => true"))["test.fixture"], false)
    }

    func testUnreadableOrUnrecognizedStateNeverPretendsEnabled() throws {
        try write()
        for answer in [result("unrecognized output"), result("", status: 1), state("unknown line"), state("\"test.fixture\" => maybe")] {
            let report = StartupItems.scan(home: home, runner: { _ in answer })
            XCTAssertNil(report.items.first?.enabled)
            XCTAssertNotNil(report.items.first?.blocked)
            XCTAssertFalse(report.issues.isEmpty)
        }
    }

    func testSymlinkAndDuplicateLabelsCannotBeChanged() throws {
        let original = try write()
        try FileManager.default.createSymbolicLink(atPath: home + "/Library/LaunchAgents/link.plist", withDestinationPath: original)
        try write("duplicate")
        let report = StartupItems.scan(home: home, runner: { _ in self.state() })
        XCTAssertEqual(report.items.count, 2)
        XCTAssertTrue(report.items.allSatisfy { $0.blocked != nil })
        XCTAssertFalse(report.issues.isEmpty)
        var writes = 0
        XCTAssertThrowsError(try StartupItems.setEnabled(false, item: report.items[0], home: home, runner: { arguments in
            if arguments.first != "print-disabled" { writes += 1 }
            return self.state()
        }))
        XCTAssertEqual(writes, 0)
    }

    func testChangedPlistOrStateRefusesBeforeMutation() throws {
        try write()
        let reviewed = try XCTUnwrap(StartupItems.scan(home: home, runner: { _ in self.state() }).items.first)
        try write(disabled: true)
        var commands: [[String]] = []
        XCTAssertThrowsError(try StartupItems.setEnabled(false, item: reviewed, home: home, runner: { arguments in
            commands.append(arguments); return self.state()
        }))
        XCTAssertTrue(commands.allSatisfy { $0.first == "print-disabled" })
        try write()
        let fresh = try XCTUnwrap(StartupItems.scan(home: home, runner: { _ in self.state() }).items.first)
        XCTAssertThrowsError(try StartupItems.setEnabled(false, item: fresh, home: home, runner: { arguments in
            XCTAssertEqual(arguments.first, "print-disabled"); return self.state("\"test.fixture\" => disabled")
        }))
    }

    func testVerifiedDisableAndEnableAreJournaledAndDoNotRunTheJob() throws {
        try write()
        var enabled = true
        var commands: [[String]] = []
        let runner: StartupItems.Runner = { arguments in
            commands.append(arguments)
            switch arguments.first {
            case "disable": enabled = false; return self.result()
            case "enable": enabled = true; return self.result()
            default: return self.state("\"test.fixture\" => " + (enabled ? "enabled" : "disabled"))
            }
        }
        let item = try XCTUnwrap(StartupItems.scan(home: home, runner: runner).items.first)
        let off = try StartupItems.setEnabled(false, item: item, home: home, runner: runner)
        XCTAssertEqual(off.enabled, false)
        let on = try StartupItems.setEnabled(true, item: off, home: home, runner: runner)
        XCTAssertEqual(on.enabled, true)
        XCTAssertEqual(commands.filter { $0.first != "print-disabled" }.map { $0.first! }, ["disable", "enable"])
        let records = OperationJournal.read(home: home)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.outcome == "succeeded" && $0.undo?.kind == "startup" })
    }

    func testSuccessfulCommandWithoutReadbackChangeIsNotSuccess() throws {
        try write()
        let runner: StartupItems.Runner = { arguments in arguments.first == "print-disabled" ? self.state() : self.result() }
        let item = try XCTUnwrap(StartupItems.scan(home: home, runner: runner).items.first)
        XCTAssertThrowsError(try StartupItems.setEnabled(false, item: item, home: home, runner: runner))
        XCTAssertEqual(OperationJournal.read(home: home).first?.outcome, "failed")
    }

    func testSystemLabelsAndUnsafeLabelsAreProtected() throws {
        try write("system", label: "com.apple.fixture")
        try write("bad", label: "bad/label")
        let report = StartupItems.scan(home: home, runner: { _ in self.state() })
        XCTAssertEqual(report.items.count, 1)
        XCTAssertNotNil(report.items.first?.blocked)
        XCTAssertFalse(report.issues.isEmpty)
    }

    func testWritableConfigurationAndTruncatedStateAreRefused() throws {
        let path = try write()
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: path)
        XCTAssertTrue(StartupItems.scan(home: home, runner: { _ in self.state() }).items.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        var answer = state()
        answer.truncated = true
        let report = StartupItems.scan(home: home, runner: { _ in answer })
        XCTAssertNil(report.items.first?.enabled)
        XCTAssertNotNil(report.items.first?.blocked)
    }
}
