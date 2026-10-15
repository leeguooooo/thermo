@testable import AgentCore
@testable import CleanKit
import Foundation
import XCTest

final class AppUpdatesTests: XCTestCase {
    var home = "", brew = "", path = ""
    var installed = "1.0", target = "2.0", revision = "first"
    var upgrades = 0
    var installChangesApp = true
    var upgradeStatus: Int32 = 0
    var arguments: [[String]] = []

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        path = home + "/Applications/Fixture.app"
        brew = home + "/brew"
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        try Data("fixture brew".utf8).write(to: URL(fileURLWithPath: brew))
        try writeVersion("1.0")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func writeVersion(_ version: String) throws {
        let plist = ["CFBundleIdentifier": "test.fixture.app", "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"), options: .atomic)
    }
    func result(_ object: [String: Any] = [:], status: Int32 = 0) -> CommandRunner.Result {
        .init(status: status, output: String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self), timedOut: false, cancelled: false)
    }
    func info() -> [String: Any] {
        ["token": "fixture", "full_token": "fixture", "name": ["Fixture"], "installed": installed, "version": target,
         "sha256": String(repeating: "a", count: 64), "artifacts": [["app": ["Fixture.app"], "target": path]], "revision": revision]
    }
    func runner(_ executable: String, _ args: [String], _ timeout: TimeInterval) -> CommandRunner.Result {
        XCTAssertEqual(executable, brew)
        arguments.append(args)
        switch args.first {
        case "outdated": return result(["casks": [["name": "fixture", "installed_versions": [installed], "current_version": target, "pinned": false]]])
        case "info": return result(["casks": [info()]])
        case "update": return result()
        case "upgrade":
            upgrades += 1
            if installChangesApp { installed = target; try! writeVersion(target) }
            return result(status: upgradeStatus)
        default: XCTFail("unexpected command"); return result(status: 1)
        }
    }
    func scan() -> AppUpdateReport { AppUpdates.scan(brew: brew, home: home, runner: runner, processes: ProcessTable(entries: [])) }
    func install(_ item: AppUpdate) -> AppUpdateResult {
        AppUpdates.install(item, home: home, runner: runner, processes: { ProcessTable(entries: []) })
    }

    func testScanIsReadOnlyAndExplicitAboutCoverage() throws {
        let report = scan()
        XCTAssertEqual(report.scope, "homebrewCasks")
        XCTAssertFalse(report.catalogRefreshed)
        XCTAssertTrue(report.issues.isEmpty)
        let item = try XCTUnwrap(report.items.first)
        XCTAssertNil(item.blocked)
        XCTAssertEqual(item.appPaths, [path])
        XCTAssertEqual(item.targetVersion, "2.0")
        XCTAssertEqual(upgrades, 0)
        XCTAssertFalse(arguments.contains { $0.first == "update" })
    }

    func testInstalledRecordsAndBundleVersionBothHaveToChange() throws {
        let plan = try XCTUnwrap(scan().items.first)
        let result = install(plan)
        XCTAssertEqual(result.outcome, "succeeded")
        XCTAssertEqual(result.versions[path], "2.0")
        XCTAssertEqual(upgrades, 1)
        let args = try XCTUnwrap(arguments.first { $0.first == "upgrade" })
        XCTAssertEqual(args.last, "fixture")
        for flag in ["--cask", "--no-quit", "--require-sha", "--skip-cask-deps"] { XCTAssertTrue(args.contains(flag)) }
        XCTAssertFalse(args.contains("--force"))
        XCTAssertEqual(OperationJournal.read(home: home).first?.outcome, "succeeded")
    }

    func testSuccessfulCommandWithoutVersionChangeIsUnconfirmed() throws {
        let plan = try XCTUnwrap(scan().items.first)
        installChangesApp = false
        XCTAssertEqual(install(plan).outcome, "unconfirmed")
        XCTAssertEqual(OperationJournal.read(home: home).first?.outcome, "partial")
    }

    func testFailedInstallerStillReadsBackButDoesNotClaimSuccess() throws {
        let plan = try XCTUnwrap(scan().items.first)
        upgradeStatus = 1
        let result = install(plan)
        XCTAssertEqual(result.outcome, "unconfirmed")
        XCTAssertEqual(result.versions[path], "2.0")
        XCTAssertEqual(arguments.last?.first, "info")
    }

    func testChangedDefinitionRefusesBeforeInstallation() throws {
        let plan = try XCTUnwrap(scan().items.first)
        revision = "changed"
        XCTAssertEqual(install(plan).outcome, "failed")
        XCTAssertEqual(upgrades, 0)
    }

    func testChangedTargetVersionRefusesBeforeInstallation() throws {
        let plan = try XCTUnwrap(scan().items.first)
        target = "3.0"
        XCTAssertEqual(install(plan).outcome, "failed")
        XCTAssertEqual(upgrades, 0)
    }

    func testPinnedAndChecksumFreeCasksAreNotOfferedForInstallation() throws {
        for pinned in [true, false] {
            let report = AppUpdates.scan(brew: brew, home: home, runner: { executable, args, timeout in
                if args.first == "outdated" {
                    return self.result(["casks": [["name": "fixture", "installed_versions": [self.installed], "current_version": self.target, "pinned": pinned]]])
                }
                if args.first == "info" {
                    var info = self.info()
                    if !pinned { info["sha256"] = "no_check" }
                    return self.result(["casks": [info]])
                }
                return self.runner(executable, args, timeout)
            }, processes: ProcessTable(entries: []))
            let item = try XCTUnwrap(report.items.first)
            XCTAssertNotNil(item.blocked)
            XCTAssertEqual(install(item).outcome, "failed")
            XCTAssertEqual(upgrades, 0)
        }
    }

    func testCaskWithAnUnsupportedSecondAppIsNotPartiallyReviewed() {
        let report = AppUpdates.scan(brew: brew, home: home, runner: { executable, args, timeout in
            if args.first == "info" {
                var info = self.info()
                info["artifacts"] = [["app": ["Fixture.app"], "target": self.path], ["app": ["Other.app"], "target": "/unsupported/Other.app"]]
                return self.result(["casks": [info]])
            }
            return self.runner(executable, args, timeout)
        }, processes: ProcessTable(entries: []))
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertNotNil(report.skipped["fixture"])
        XCTAssertEqual(upgrades, 0)
    }

    func testReplacedBundleRefusesBeforeInstallation() throws {
        let plan = try XCTUnwrap(scan().items.first)
        try FileManager.default.moveItem(atPath: path, toPath: path + ".old")
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        try writeVersion("1.0")
        XCTAssertEqual(install(plan).outcome, "failed")
        XCTAssertEqual(upgrades, 0)
    }

    func testAppThatUpdatedItselfDoesNotGetOverwrittenUsingStaleBrewRecord() throws {
        let plan = try XCTUnwrap(scan().items.first)
        try writeVersion("2.0")
        let report = scan()
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertNotNil(report.skipped["fixture"])
        XCTAssertEqual(install(plan).outcome, "failed")
        XCTAssertEqual(upgrades, 0)
    }

    func testSubprocessInstallerReceivesSafeEnvironmentAndVerifiedResult() throws {
        let before = try JSONSerialization.data(withJSONObject: ["casks": [info()]])
        installed = target
        let after = try JSONSerialization.data(withJSONObject: ["casks": [info()]])
        installed = "1.0"
        let outdated = try JSONSerialization.data(withJSONObject: ["casks": [["name": "fixture", "installed_versions": [installed], "current_version": target]]])
        try before.write(to: URL(fileURLWithPath: home + "/before.json"))
        try after.write(to: URL(fileURLWithPath: home + "/after.json"))
        try outdated.write(to: URL(fileURLWithPath: home + "/outdated.json"))
        let marker = Shell.quote(home + "/installed")
        let script = """
        #!/bin/sh
        case "$1" in
          outdated) /bin/cat \(Shell.quote(home + "/outdated.json")) ;;
          info)
            if [ -f \(marker) ]; then /bin/cat \(Shell.quote(home + "/after.json"));
            else /bin/cat \(Shell.quote(home + "/before.json")); fi ;;
          upgrade)
            [ "$HOMEBREW_NO_AUTO_UPDATE" = 1 ] || exit 11
            [ "$HOMEBREW_NO_ANALYTICS" = 1 ] || exit 12
            [ "$HOMEBREW_NO_INSTALL_CLEANUP" = 1 ] || exit 13
            [ "$HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK" = 1 ] || exit 14
            /usr/bin/plutil -replace CFBundleShortVersionString -string 2.0 \(Shell.quote(path + "/Contents/Info.plist")) || exit 15
            /usr/bin/touch \(marker) ;;
          *) exit 16 ;;
        esac
        """
        try Data(script.utf8).write(to: URL(fileURLWithPath: brew))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: brew)
        let report = AppUpdates.scan(brew: brew, home: home, runner: AppUpdates.run, processes: ProcessTable(entries: []))
        let item = try XCTUnwrap(report.items.first)
        XCTAssertNil(item.blocked)
        let result = AppUpdates.install(item, home: home, runner: AppUpdates.run, processes: { ProcessTable(entries: []) })
        XCTAssertEqual(result.outcome, "succeeded")
        XCTAssertEqual(result.versions[path], "2.0")
        XCTAssertEqual(OperationJournal.read(home: home).first?.outcome, "succeeded")
    }

    func testMalformedOrTruncatedMetadataFailsClosed() {
        var invalid = result(["unexpected": []])
        for truncated in [false, true] {
            invalid.truncated = truncated
            let report = AppUpdates.scan(brew: brew, home: home, runner: { _, _, _ in invalid }, processes: ProcessTable(entries: []))
            XCTAssertTrue(report.items.isEmpty)
            XCTAssertFalse(report.issues.isEmpty)
        }
        XCTAssertFalse(AppUpdates.validToken("--force"))
        XCTAssertFalse(AppUpdates.validToken("foo;rm"))
        XCTAssertFalse(AppUpdates.validToken("foo/../bar"))
        XCTAssertTrue(AppUpdates.validToken("owner/tap/app-name"))
    }

    func testCatalogRefreshIsExplicitAndItsFailureStopsTheCheck() {
        let report = AppUpdates.scan(refreshCatalog: true, brew: brew, home: home, runner: { executable, args, timeout in
            if args.first == "update" { return self.result(status: 1) }
            XCTFail("must stop after a failed catalog refresh"); return self.runner(executable, args, timeout)
        })
        XCTAssertFalse(report.catalogRefreshed)
        XCTAssertFalse(report.issues.isEmpty)
        XCTAssertTrue(report.items.isEmpty)
    }

    func testRunningAppIsBlockedAndNeverQuitByThermo() throws {
        let table = ProcessTable(entries: [AgentProcess(pid: 1234, name: "Fixture", executable: path + "/Contents/MacOS/Fixture")])
        let report = AppUpdates.scan(brew: brew, home: home, runner: runner, processes: table)
        let item = try XCTUnwrap(report.items.first)
        XCTAssertEqual(item.blocked, "Quit this app before updating it")
        XCTAssertEqual(install(item).outcome, "failed")
        XCTAssertEqual(upgrades, 0)
    }

    func testCompositeVersionRequiresMatchingBuildNumber() throws {
        let plan = try XCTUnwrap(scan().items.first)
        var composite = plan
        composite.targetVersion = "2.0,123"
        XCTAssertFalse(AppUpdates.bundleMatches(path, version: "1.0,123"))
        let plist = ["CFBundleIdentifier": "test.fixture.app", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "123"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        XCTAssertTrue(AppUpdates.bundleMatches(path, version: "1.0,123"))
        XCTAssertFalse(AppUpdates.bundleMatches(path, version: composite.targetVersion))
    }
}
