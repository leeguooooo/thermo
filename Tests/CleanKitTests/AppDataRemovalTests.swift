import AgentCore
@testable import CleanKit
import Darwin
import Foundation
import XCTest

final class AppDataRemovalTests: XCTestCase {
    var home = ""
    var appPath: String { home + "/Applications/Fixture.app" }
    var cachePath: String { home + "/Library/Caches/com.example.fixture" }
    let empty = ProcessTable(entries: [])
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: appPath + "/Contents", withIntermediateDirectories: true)
        try info()
        try data(cachePath)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func info(id: String = "com.example.fixture", version: String = "1") throws {
        let value = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: appPath + "/Contents/Info.plist"), options: .atomic)
    }
    func data(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try Data(repeating: 37, count: 4096).write(to: URL(fileURLWithPath: path + "/data"))
    }
    func plan(removeApp: Bool = false) throws -> UninstallPlan {
        let app = try XCTUnwrap(AppUninstaller.read(appPath))
        return AppUninstaller.plan(app, installed: [app], home: home, processes: empty, removeApp: removeApp)
    }
    func move(_ path: String) throws -> URL {
        let trash = home + "/.Trash"
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        let destination = URL(fileURLWithPath: trash + "/" + UUID().uuidString)
        try FileManager.default.moveItem(atPath: path, toPath: destination.path)
        return destination
    }
    func execute(_ plan: UninstallPlan, processes: ProcessTable? = nil) -> CleanResult {
        AppUninstaller.uninstall(plan, home: home, processes: { processes ?? self.empty }, move: move)
    }

    func testDataOnlyMovesAndRestoresDataWithoutTouchingTheBundle() throws {
        let reviewed = try plan()
        let identity = AppReviewIdentity.capture(appPath)
        let info = try Data(contentsOf: URL(fileURLWithPath: appPath + "/Contents/Info.plist"))
        XCTAssertNil(reviewed.blocked)
        XCTAssertFalse(reviewed.removesApp)
        XCTAssertEqual(reviewed.paths, [cachePath])
        XCTAssertEqual(reviewed.bytes, reviewed.app.leftoverBytes)
        XCTAssertEqual(reviewed.app.bundleSizeState, .unmeasured)
        let decoded = try JSONDecoder().decode(UninstallPlan.self, from: JSONEncoder().encode(reviewed))
        let result = execute(decoded)
        XCTAssertTrue(result.failed.isEmpty, "\(result.failed)")
        XCTAssertEqual(result.removed, [cachePath])
        XCTAssertEqual(AppReviewIdentity.capture(appPath), identity)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: appPath + "/Contents/Info.plist")), info)
        let history = try XCTUnwrap(OperationJournal.read(home: home).first)
        XCTAssertEqual(history.action, "removeData")
        XCTAssertEqual(history.undo?.kind, "trashBatch")
        let restored = try TrashBatches.restore(id: XCTUnwrap(result.trashBatchID), home: home)
        XCTAssertEqual(restored.items.map(\.status), ["restored"])
        XCTAssertTrue(FS.exists(cachePath))
        XCTAssertEqual(AppReviewIdentity.capture(appPath), identity)
    }

    func testBundleWhitelistKeepsTheBundleWithoutBlockingDataOnlyReview() throws {
        _ = try Whitelist.add([appPath], home: home)
        XCTAssertNil(try plan().blocked)
        XCTAssertNotNil(try plan(removeApp: true).blocked)
        XCTAssertEqual(execute(try plan()).removed, [cachePath])
        XCTAssertTrue(FS.exists(appPath))
    }

    func testPersonalDataAndWhitelistedDataStayInPlace() throws {
        try info(id: "com.google.Chrome")
        let personal = home + "/Library/Application Support/com.google.Chrome"
        let saved = home + "/Library/Logs/com.google.Chrome"
        let cache = home + "/Library/Caches/com.google.Chrome"
        try data(personal); try data(saved); try data(cache)
        _ = try Whitelist.add([saved], home: home)
        let reviewed = try plan()
        XCTAssertTrue(reviewed.kept?.contains { $0.path == personal } == true)
        XCTAssertTrue(reviewed.whitelisted?.contains(saved) == true)
        XCTAssertFalse(reviewed.paths.contains(appPath))
        let result = execute(reviewed)
        XCTAssertEqual(result.removed, [cache])
        XCTAssertTrue(FS.exists(personal)); XCTAssertTrue(FS.exists(saved)); XCTAssertTrue(FS.exists(appPath))
    }

    func testSelectionCannotSmuggleInTheBundleItsContentsOrAliasedParent() throws {
        let reviewed = try plan()
        let alias = home + "/LinkedApplications"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: home + "/Applications")
        for path in [appPath, appPath + "/Contents", home + "/Applications", alias + "/Fixture.app"] {
            var changed = reviewed; changed.paths = [path]
            let result = execute(changed)
            XCTAssertTrue(result.removed.isEmpty)
            XCTAssertEqual(result.failed[appPath], tr("The removal selection changed; review it again"))
        }
        XCTAssertTrue(FS.exists(appPath)); XCTAssertTrue(FS.exists(cachePath))
    }

    func testChangedAppOrRunningAppRefusesDataOnlyRemoval() throws {
        let reviewed = try plan()
        let running = ProcessTable(entries: [AgentProcess(pid: 42, name: "Fixture", executable: appPath + "/Contents/MacOS/Fixture")])
        XCTAssertTrue(execute(reviewed, processes: running).removed.isEmpty)
        try info(version: "2")
        let result = execute(reviewed)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.failed[appPath], tr("The app changed after review; review the data removal again"))
        XCTAssertTrue(FS.exists(cachePath))
    }

    func testReadonlyBundleCanBeKeptWhileItsUserDataMoves() throws {
        try XCTSkipIf(getuid() == 0, "requires ordinary user permissions")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: appPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appPath) }
        XCTAssertNotNil(try plan(removeApp: true).blocked)
        let reviewed = try plan()
        XCTAssertNil(reviewed.blocked)
        XCTAssertEqual(execute(reviewed).removed, [cachePath])
        XCTAssertTrue(FS.exists(appPath))
    }

    func testMissingModeInADataOnlySerializedPlanFailsClosed() throws {
        let reviewed = try plan()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reviewed)) as? [String: Any])
        json.removeValue(forKey: "removeApp")
        let decoded = try JSONDecoder().decode(UninstallPlan.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(decoded.removesApp, "legacy plans default to normal uninstall")
        XCTAssertTrue(execute(decoded).removed.isEmpty)
        XCTAssertTrue(FS.exists(appPath)); XCTAssertTrue(FS.exists(cachePath))
        var normal = try plan(removeApp: true); normal.removeApp = nil
        XCTAssertNil(AppUninstaller.refusal(normal, home: home, processes: empty))
    }

    func testCancelledReviewCannotAuthorizeDataRemoval() throws {
        let app = try XCTUnwrap(AppUninstaller.read(appPath))
        let token = ScanCancellation(); token.cancel()
        let reviewed = AppUninstaller.plan(app, installed: [app], home: home, processes: empty, removeApp: false, cancellation: token)
        XCTAssertEqual(reviewed.blocked, tr("Review stopped; review again before removing files"))
        XCTAssertNil(reviewed.appIdentity)
        let result = execute(reviewed)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.failed[appPath], reviewed.blocked)
        XCTAssertTrue(FS.exists(appPath)); XCTAssertTrue(FS.exists(cachePath))
    }

    func testReplacedDataAndEmptyDataPlansCannotRemoveAnythingUnexpected() throws {
        let reviewed = try plan()
        try FileManager.default.moveItem(atPath: cachePath, toPath: cachePath + ".old")
        try data(cachePath)
        XCTAssertTrue(execute(reviewed).removed.isEmpty)
        XCTAssertTrue(FS.exists(appPath)); XCTAssertTrue(FS.exists(cachePath))
        try FileManager.default.removeItem(atPath: cachePath)
        let empty = try plan()
        XCTAssertTrue(empty.paths.isEmpty)
        XCTAssertNotNil(empty.blocked)
    }
}
