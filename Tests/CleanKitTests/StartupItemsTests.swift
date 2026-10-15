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
        let off = StartupItems.scan(home: home, includeSystem: false, runner: { _ in self.state() })
        XCTAssertEqual(off.items.first?.enabled, false)
        let on = StartupItems.scan(home: home, includeSystem: false, runner: { _ in self.state("\"test.fixture\" => enabled") })
        XCTAssertEqual(on.items.first?.enabled, true)
        XCTAssertEqual(on.items.first?.program, "/bin/echo")
        XCTAssertTrue(on.issues.isEmpty)
        XCTAssertEqual(try StartupItems.overrides(state("\"test.fixture\" => true"))["test.fixture"], false)
    }

    func testUnreadableOrUnrecognizedStateNeverPretendsEnabled() throws {
        try write()
        for answer in [result("unrecognized output"), result("", status: 1), state("unknown line"), state("\"test.fixture\" => maybe")] {
            let report = StartupItems.scan(home: home, includeSystem: false, runner: { _ in answer })
            XCTAssertNil(report.items.first?.enabled)
            XCTAssertNotNil(report.items.first?.blocked)
            XCTAssertFalse(report.issues.isEmpty)
        }
    }

    func testSymlinkAndDuplicateLabelsCannotBeChanged() throws {
        let original = try write()
        try FileManager.default.createSymbolicLink(atPath: home + "/Library/LaunchAgents/link.plist", withDestinationPath: original)
        try write("duplicate")
        let report = StartupItems.scan(home: home, includeSystem: false, runner: { _ in self.state() })
        XCTAssertEqual(report.items.count, 2)
        XCTAssertTrue(report.items.allSatisfy { $0.blocked != nil })
        XCTAssertFalse(report.issues.isEmpty)
        var writes = 0
        XCTAssertThrowsError(try StartupItems.setEnabled(false, item: report.items[0], home: home, includeSystem: false, runner: { arguments in
            if arguments.first != "print-disabled" { writes += 1 }
            return self.state()
        }))
        XCTAssertEqual(writes, 0)
    }

    func testChangedPlistOrStateRefusesBeforeMutation() throws {
        try write()
        let reviewed = try XCTUnwrap(StartupItems.scan(home: home, includeSystem: false, runner: { _ in self.state() }).items.first)
        try write(disabled: true)
        var commands: [[String]] = []
        XCTAssertThrowsError(try StartupItems.setEnabled(false, item: reviewed, home: home, includeSystem: false, runner: { arguments in
            commands.append(arguments); return self.state()
        }))
        XCTAssertTrue(commands.allSatisfy { $0.first == "print-disabled" })
        try write()
        let fresh = try XCTUnwrap(StartupItems.scan(home: home, includeSystem: false, runner: { _ in self.state() }).items.first)
        XCTAssertThrowsError(try StartupItems.setEnabled(false, item: fresh, home: home, includeSystem: false, runner: { arguments in
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
        let item = try XCTUnwrap(StartupItems.scan(home: home, includeSystem: false, runner: runner).items.first)
        let off = try StartupItems.setEnabled(false, item: item, home: home, includeSystem: false, runner: runner)
        XCTAssertEqual(off.enabled, false)
        let on = try StartupItems.setEnabled(true, item: off, home: home, includeSystem: false, runner: runner)
        XCTAssertEqual(on.enabled, true)
        XCTAssertEqual(commands.filter { $0.first != "print-disabled" }.map { $0.first! }, ["disable", "enable"])
        let records = OperationJournal.read(home: home)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.outcome == "succeeded" && $0.undo?.kind == "startup" })
    }

    func testSuccessfulCommandWithoutReadbackChangeIsNotSuccess() throws {
        try write()
        let runner: StartupItems.Runner = { arguments in arguments.first == "print-disabled" ? self.state() : self.result() }
        let item = try XCTUnwrap(StartupItems.scan(home: home, includeSystem: false, runner: runner).items.first)
        XCTAssertThrowsError(try StartupItems.setEnabled(false, item: item, home: home, includeSystem: false, runner: runner))
        XCTAssertEqual(OperationJournal.read(home: home).first?.outcome, "failed")
    }

    func testSystemLabelsAndUnsafeLabelsAreProtected() throws {
        try write("system", label: "com.apple.fixture")
        try write("bad", label: "bad/label")
        let report = StartupItems.scan(home: home, includeSystem: false, runner: { _ in self.state() })
        XCTAssertEqual(report.items.count, 1)
        XCTAssertNotNil(report.items.first?.blocked)
        XCTAssertFalse(report.issues.isEmpty)
    }

    func testWritableConfigurationAndTruncatedStateAreRefused() throws {
        let path = try write()
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: path)
        XCTAssertTrue(StartupItems.scan(home: home, includeSystem: false, runner: { _ in self.state() }).items.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        var answer = state()
        answer.truncated = true
        let report = StartupItems.scan(home: home, includeSystem: false, runner: { _ in answer })
        XCTAssertNil(report.items.first?.enabled)
        XCTAssertNotNil(report.items.first?.blocked)
    }

    func fixtureLocations() throws -> [StartupItems.Location] {
        let roots: [(String, StartupScope)] = [("/Library/LaunchAgents", .userAgent), ("/Shared/LaunchAgents", .sharedAgent), ("/Shared/LaunchDaemons", .systemDaemon)]
        return try roots.map { suffix, scope in
            let path = home + suffix
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return .init(path: path, scope: scope, owner: getuid())
        }
    }

    func copyFixture(to location: StartupItems.Location, label: String = "test.fixture") throws -> String {
        let source = try write(label: label)
        let path = location.path + "/fixture.plist"
        try FileManager.default.copyItem(atPath: source, toPath: path)
        try FileManager.default.removeItem(atPath: source)
        return path
    }

    func testScopesReadTheirOwnDomainsAndMarkSystemAuthorization() throws {
        let locations = try fixtureLocations()
        try copyFixture(to: locations[1])
        try copyFixture(to: locations[2])
        let report = StartupItems.scan(home: home, locations: locations, runner: { args in
            XCTAssertEqual(args.first, "print-disabled")
            return self.state("\"test.fixture\" => " + (args.last == "system" ? "disabled" : "enabled"))
        })
        XCTAssertEqual(report.items.count, 2)
        let shared = try XCTUnwrap(report.items.first { $0.effectiveScope == .sharedAgent })
        let daemon = try XCTUnwrap(report.items.first { $0.effectiveScope == .systemDaemon })
        XCTAssertEqual(shared.enabled, true); XCTAssertNil(shared.blocked)
        XCTAssertEqual(daemon.enabled, false); XCTAssertNil(daemon.blocked)
        XCTAssertTrue(daemon.requiresAdministrator)
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testSharedAgentChangesOnlyCurrentUserDomainAndKeepsPlist() throws {
        let locations = try fixtureLocations()
        let path = try copyFixture(to: locations[1])
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        var enabled = true, changes: [[String]] = []
        let runner: StartupItems.Runner = { args in
            if args.first == "disable" { changes.append(args); enabled = false; return self.result() }
            return self.state("\"test.fixture\" => " + (enabled ? "enabled" : "disabled"))
        }
        let item = try XCTUnwrap(StartupItems.scan(home: home, locations: locations, runner: runner).items.first)
        let after = try StartupItems.setEnabled(false, item: item, home: home, locations: locations, runner: runner)
        XCTAssertEqual(after.enabled, false)
        XCTAssertEqual(changes, [["disable", "gui/\(getuid())/test.fixture"]])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
        XCTAssertEqual(OperationJournal.read(home: home).first?.undo?.ref, path)
    }

    func testForgedSystemRowNeverSendsAMutatingCommand() throws {
        let locations = try fixtureLocations()
        try copyFixture(to: locations[2])
        var changes: [[String]] = []
        let runner: StartupItems.Runner = { args in
            if args.first != "print-disabled" { changes.append(args) }
            return self.state()
        }
        var item = try XCTUnwrap(StartupItems.scan(home: home, locations: locations, runner: runner).items.first)
        item.blocked = nil
        item.scope = .userAgent
        XCTAssertThrowsError(try StartupItems.setEnabled(false, item: item, home: home, locations: locations, runner: runner))
        XCTAssertTrue(changes.isEmpty)
    }

    func testDuplicateLabelsAcrossUserAndSharedAgentsAreBlocked() throws {
        let locations = try fixtureLocations()
        try copyFixture(to: locations[1])
        try write()
        let report = StartupItems.scan(home: home, locations: locations, runner: { _ in self.state() })
        XCTAssertEqual(report.items.count, 2)
        XCTAssertTrue(report.items.allSatisfy { $0.blocked != nil })
    }

    func testSystemReadFailureDoesNotHideUserState() throws {
        let locations = try fixtureLocations()
        try copyFixture(to: locations[2])
        try write()
        let report = StartupItems.scan(home: home, locations: locations, runner: { args in
            args.last == "system" ? self.result("denied", status: 1) : self.state()
        })
        XCTAssertEqual(report.items.first { $0.effectiveScope == .userAgent }?.enabled, true)
        XCTAssertNil(report.items.first { $0.effectiveScope == .systemDaemon }?.enabled)
        XCTAssertEqual(report.issues.count, 1)
    }

    func testScopeMismatchAndUnsafeOwnerAreRejected() throws {
        var locations = try fixtureLocations()
        try copyFixture(to: locations[1])
        let runner: StartupItems.Runner = { args in
            XCTAssertEqual(args.first, "print-disabled")
            return self.state()
        }
        var item = try XCTUnwrap(StartupItems.scan(home: home, locations: locations, runner: runner).items.first)
        item.scope = .userAgent
        XCTAssertThrowsError(try StartupItems.setEnabled(false, item: item, home: home, locations: locations, runner: runner))
        locations[1].owner = getuid() &+ 1
        let report = StartupItems.scan(home: home, locations: locations, runner: runner)
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertEqual(report.issues.count, 1)
    }
}
