import AgentCore
@testable import CleanKit
import XCTest

final class AppInventoryReportTests: XCTestCase {
    var home = "", apps = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("inventory-report-" + UUID().uuidString).resolvingSymlinksInPath().path
        apps = home + "/Applications"
        try FileManager.default.createDirectory(atPath: apps, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func bundle() throws -> String {
        let path = apps + "/Fixture.app"
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier":"com.example.inventory", "CFBundleVersion":"1", "SUFeedURL":"https://updates.example.test/feed?token=SYNTHETIC_PRIVATE_FEED"], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        return path
    }
    func testMissingOptionalDirectoryIsEmptyButStructuralFailureIsIncomplete() throws {
        let absent = AppUninstaller.installedReport(home: home, dirs: [home + "/absent"])
        XCTAssertTrue(absent.complete); XCTAssertTrue(absent.apps.isEmpty)
        let file = home + "/not-a-directory"; try Data().write(to: URL(fileURLWithPath: file))
        let failed = AppUninstaller.installedReport(home: home, dirs: [file])
        XCTAssertFalse(failed.complete); XCTAssertFalse(failed.scopeComplete); XCTAssertFalse(failed.issues.isEmpty)
    }
    func testSourceReportKeepsKnownAppsAndNeverExportsPrivateFeedURL() throws {
        let path = try bundle(), bad = home + "/not-a-directory"
        try Data().write(to: URL(fileURLWithPath: bad))
        let report = NativeAppUpdates.sourceReport(home: home, dirs: [apps,bad])
        XCTAssertFalse(report.complete); XCTAssertEqual(report.sources.map(\.app.path), [path])
        XCTAssertTrue(report.sources[0].canCheck)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(json.contains("SYNTHETIC_PRIVATE_FEED")); XCTAssertFalse(json.contains("/feed?"))
    }
    func testMissingAppMetadataRemainsVisibleAndIncomplete() throws {
        let path = apps + "/Unknown.app"; try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let report = AppUninstaller.installedReport(home: home, dirs: [apps])
        XCTAssertEqual(report.apps.map(\.path), [path]); XCTAssertFalse(report.complete); XCTAssertTrue(report.scopeComplete)
        XCTAssertTrue(report.issues.contains { $0.path == path })
    }
    func testCancellationIsNotAnEmptySuccess() throws {
        _ = try bundle()
        let token = ScanCancellation(); token.cancel()
        let before = NativeAppUpdates.sourceReport(home: home, dirs: [apps], cancellation: token)
        XCTAssertTrue(before.cancelled); XCTAssertFalse(before.complete)
        let middle = ScanCancellation()
        let partial = AppUninstaller.installedReport(home: home, dirs: [apps], cancellation: middle, afterEnumeration: { middle.cancel() })
        XCTAssertEqual(partial.apps.count, 1); XCTAssertTrue(partial.cancelled); XCTAssertFalse(partial.complete)
    }
    func testChangedDirectoryDoesNotClaimCompleteCoverage() throws {
        _ = try bundle()
        let report = AppUninstaller.installedReport(home: home, dirs: [apps], cancellation: nil, afterEnumeration: {
            try! Data().write(to: URL(fileURLWithPath: self.apps + "/new-entry"))
        })
        XCTAssertEqual(report.apps.count, 1); XCTAssertFalse(report.complete)
        XCTAssertTrue(report.issues.contains { $0.message == "Application directory changed during discovery" })
    }
    func testIssueListIsBoundedWithoutHidingIncompleteness() throws {
        for index in 0..<140 { try FileManager.default.createDirectory(atPath: apps + "/Unknown-\(index).app", withIntermediateDirectories: true) }
        let report = AppUninstaller.installedReport(home: home, dirs: [apps])
        XCTAssertEqual(report.apps.count, 140); XCTAssertEqual(report.issues.count, 128)
        XCTAssertTrue(report.issuesTruncated); XCTAssertFalse(report.complete)
    }
    func testAppDeclaredShortIdentifiersAreNotMistakenForMissingMetadata() throws {
        for (index, id) in ["md.obsidian", "SwitchHosts"].enumerated() {
            let path = apps + "/Short-\(index).app"
            try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier":id, "CFBundleVersion":"1"], format: .xml, options: 0)
                .write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
            XCTAssertEqual(AppUninstaller.read(path)?.bundleID, id)
            XCTAssertFalse(AppUninstaller.isBundleID(id), "Orphan-directory inference keeps its stricter matching rule")
        }
        let report = NativeAppUpdates.sourceReport(home: home, dirs: [apps])
        XCTAssertEqual(report.sources.count, 2); XCTAssertTrue(report.complete)
        XCTAssertFalse(AppOwnershipSnapshot.validDeclaredID("../outside"))
    }

}
