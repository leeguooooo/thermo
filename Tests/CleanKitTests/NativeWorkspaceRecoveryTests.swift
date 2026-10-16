@testable import AgentCore
@testable import CleanKit
import Darwin
import Foundation
import XCTest

final class NativeWorkspaceRecoveryTests: XCTestCase {
    var home = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func preserved(saved: Bool = true) throws -> NativeUpdateTransaction.PreservedWorkspaceFailure {
        let root = try NativeUpdateTransaction.storage(home)
        let path = root + "/" + UUID().uuidString
        try NativeUpdateTransaction.privateDirectory(path)
        try Data("preserved payload".utf8).write(to: URL(fileURLWithPath: path + "/payload.archive"))
        if !saved { try FileManager.default.createDirectory(atPath: root + "/workspace-" + (path as NSString).lastPathComponent + ".json", withIntermediateDirectories: false) }
        return NativeUpdateTransaction.preserveWorkspace(path, identity: try XCTUnwrap(FileIdentity.of(path)),
            target: home + "/Applications/Fixture.app", reason: "The update image mount or cleanup could not be confirmed; its workspace was preserved for manual inspection", home: home)
    }
    func testPreservedWorkspaceSurvivesASeparateRecoveryReadAndCanBeInspected() throws {
        let failure = try preserved()
        XCTAssertTrue(failure.recorded)
        let report = NativeUpdateTransaction.recovery(home: home)
        XCTAssertTrue(report.issues.isEmpty); XCTAssertEqual(report.workspaces?.map(\.id), [failure.workspace.id])
        let url = try NativeUpdateTransaction.preservedWorkspaceURL(try XCTUnwrap(report.workspaces?.first), home: home)
        XCTAssertEqual(url.path, failure.workspace.path)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("payload.archive")), Data("preserved payload".utf8))
        XCTAssertTrue(report.records.isEmpty, "preserved preparation is not an application replacement receipt")
    }
    func testChangedWorkspaceCannotBeOpenedAsTheOriginal() throws {
        let failure = try preserved()
        try FileManager.default.moveItem(atPath: failure.workspace.path, toPath: failure.workspace.path + "-kept")
        try NativeUpdateTransaction.privateDirectory(failure.workspace.path)
        XCTAssertThrowsError(try NativeUpdateTransaction.preservedWorkspaceURL(failure.workspace, home: home))
        let report = NativeUpdateTransaction.recovery(home: home)
        XCTAssertEqual(report.workspaces?.count, 1); XCTAssertFalse(report.issues.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: failure.workspace.path + "-kept/payload.archive"))
    }
    func testRecordCannotExpandInspectionToAnArbitraryPath() throws {
        let failure = try preserved()
        var record = failure.workspace
        record.path = home
        XCTAssertThrowsError(try NativeUpdateTransaction.preservedWorkspaceURL(record, home: home))
        let file = try NativeUpdateTransaction.storage(home) + "/workspace-" + record.id + ".json"
        try JSONEncoder().encode(record).write(to: URL(fileURLWithPath: file))
        let report = NativeUpdateTransaction.recovery(home: home)
        XCTAssertTrue(report.workspaces?.isEmpty ?? true); XCTAssertFalse(report.issues.isEmpty)
    }
    func testFailedRecordWriteDoesNotDeleteWorkspaceAndStillReturnsInspectablePath() throws {
        let failure = try preserved(saved: false)
        XCTAssertFalse(failure.recorded)
        XCTAssertNoThrow(try NativeUpdateTransaction.preservedWorkspaceURL(failure.workspace, home: home))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failure.workspace.path + "/payload.archive"))
        XCTAssertFalse(NativeUpdateTransaction.recovery(home: home).issues.isEmpty)
    }
    func testFIFORecoveryRecordsCannotBlockCLIAndDoNotHideKnownWorkspace() throws {
        let failure = try preserved()
        let root = try NativeUpdateTransaction.storage(home)
        for name in [UUID().uuidString + ".json", "workspace-" + UUID().uuidString + ".json"] {
            XCTAssertEqual(mkfifo(root + "/" + name, 0o600), 0)
        }
        let cli = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("thermo")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli.path), "requires built sibling CLI")
        var env = ProcessInfo.processInfo.environment; env["CFFIXED_USER_HOME"] = home
        let result = CommandRunner.run(cli.path, arguments: ["apps", "updates", "recovery", "--json"], environment: env, timeout: 2)
        XCTAssertFalse(result.timedOut); XCTAssertEqual(result.status, 0, result.output)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        XCTAssertEqual((json["issues"] as? [String])?.count, 2)
        XCTAssertEqual((json["workspaces"] as? [[String: Any]])?.first?["id"] as? String, failure.workspace.id)
    }
    func testLegacyResultsAndReportsDecodeWithoutWorkspaceFields() throws {
        let result = try JSONDecoder().decode(NativeInstallResult.self, from: Data(#"{"outcome":"failed","message":"old"}"#.utf8))
        XCTAssertNil(result.preservedWorkspace); XCTAssertNil(result.workspaceRecordSaved)
        XCTAssertNil(result.cleanupIssue)
        XCTAssertNil(result.additionalPreservedWorkspaces)
        let report = try JSONDecoder().decode(NativeRecoveryReport.self, from: Data(#"{"records":[],"issues":[]}"#.utf8))
        XCTAssertNil(report.workspaces)
    }
    func testRecoveryFolderInspectionDoesNotCreateMissingStorage() throws {
        XCTAssertThrowsError(try NativeUpdateTransaction.recoveryFolderURL(home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/Library/Application Support/Thermo/app-updates"))
        _ = try preserved()
        XCTAssertEqual(try NativeUpdateTransaction.recoveryFolderURL(home: home).path, try NativeUpdateTransaction.storage(home))
    }

    func testDownloadWorkspaceKindIsPersistedAndInspectedWithinItsOwnNamespace() throws {
        let root = try NativeUpdateTransaction.storage(home), path = root + "/download-" + UUID().uuidString
        try NativeUpdateTransaction.privateDirectory(path)
        let failure = NativeUpdateTransaction.preserveWorkspace(path, identity: try XCTUnwrap(FileIdentity.of(path)), target: "/fixture.app", reason: "fixture", home: home, kind: "download")
        XCTAssertTrue(failure.recorded)
        let record = try XCTUnwrap(NativeUpdateTransaction.recovery(home: home).workspaces?.first)
        XCTAssertEqual(record.kind, "download"); XCTAssertEqual(try NativeUpdateTransaction.preservedWorkspaceURL(record, home: home).path, path)
    }
    func testWorkspaceKindCannotExpandOrChangeTheAllowedDirectory() throws {
        var record = try preserved().workspace
        record.kind = "download"
        XCTAssertThrowsError(try NativeUpdateTransaction.preservedWorkspaceURL(record, home: home))
        record.kind = "arbitrary"
        XCTAssertThrowsError(try NativeUpdateTransaction.preservedWorkspaceURL(record, home: home))
    }
}
