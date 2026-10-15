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
        return AppUninstaller.plan(app, installed: [app], home: home, processes: empty, removeApp: removeApp, ownershipDirectories: [home + "/Applications"])
    }
    func move(_ path: String) throws -> URL {
        let trash = home + "/.Trash"
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        let destination = URL(fileURLWithPath: trash + "/" + UUID().uuidString)
        try FileManager.default.moveItem(atPath: path, toPath: destination.path)
        return destination
    }
    func execute(_ plan: UninstallPlan, processes: ProcessTable? = nil) -> CleanResult {
        AppUninstaller.uninstall(plan, home: home, processes: { processes ?? self.empty }, ownershipDirectories: [home + "/Applications"], move: move)
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
        let reviewed = AppUninstaller.plan(app, installed: [app], home: home, processes: empty, removeApp: false, cancellation: token, ownershipDirectories: [home + "/Applications"])
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

    func peer(_ name: String, id: String) throws -> String {
        let path = home + "/Applications/" + name + ".app"
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        return path
    }

    func testReviewRecomputesCachedDataOwnershipAgainstNewlyInstalledPeers() throws {
        let group = home + "/Library/Group Containers/TEAM.com.example.fixture"
        try data(group)
        var cached = try XCTUnwrap(AppUninstaller.read(appPath))
        cached.leftovers = [AppLeftover(path: group, bytes: 999, sizeState: .complete)]
        _ = try peer("Peer", id: "com.example.peer")
        let reviewed = AppUninstaller.plan(cached, installed: [cached], home: home, processes: empty,
                                          removeApp: false, ownershipDirectories: [home + "/Applications"])
        XCTAssertNil(reviewed.blocked)
        XCTAssertTrue(reviewed.paths.contains(cachePath))
        XCTAssertFalse(reviewed.paths.contains(group))
        XCTAssertTrue(reviewed.ownershipKept?.contains(group) == true)
        XCTAssertEqual(reviewed.ownership?.claims.count, 2)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reviewed)) as? [String: Any])
        let ownership = try XCTUnwrap(json["ownership"] as? [String: Any])
        XCTAssertNil(ownership["claims"], "a single app's plan exports an inventory fingerprint, not unrelated app names")
        let roundTrip = try JSONDecoder().decode(UninstallPlan.self, from: JSONEncoder().encode(reviewed))
        XCTAssertEqual(roundTrip.ownership, reviewed.ownership)
        XCTAssertEqual(execute(reviewed).removed, [cachePath])
        XCTAssertTrue(FS.exists(group))
    }

    func testPeerInstalledAfterReviewPreventsBothFullAndDataOnlyRemoval() throws {
        for removeApp in [true, false] {
            let reviewed = try plan(removeApp: removeApp)
            let path = try peer("Peer", id: "com.example.fixture")
            let result = execute(reviewed)
            XCTAssertTrue(result.removed.isEmpty)
            XCTAssertEqual(result.failed[appPath], tr("Installed apps changed or ownership could not be verified; review associated data again"))
            XCTAssertTrue(FS.exists(appPath)); XCTAssertTrue(FS.exists(cachePath))
            try FileManager.default.removeItem(atPath: path)
        }
    }

    func testSameInodePreferenceRewriteIsRefusedAfterReview() throws {
        let pref = home + "/Library/Preferences/com.example.fixture.plist"
        try FileManager.default.createDirectory(atPath: (pref as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("before".utf8).write(to: URL(fileURLWithPath: pref))
        for removeApp in [true, false] {
            let reviewed = try plan(removeApp: removeApp)
            let identity = FileIdentity.of(pref)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: pref))
            try handle.truncate(atOffset: 0); try handle.write(contentsOf: Data(UUID().uuidString.utf8)); try handle.close()
            XCTAssertEqual(FileIdentity.of(pref), identity)
            let result = execute(reviewed)
            XCTAssertTrue(result.removed.isEmpty)
            XCTAssertEqual(result.failed[pref], tr("Associated data changed after review; review it again"))
            XCTAssertTrue(FS.exists(appPath)); XCTAssertTrue(FS.exists(pref)); XCTAssertTrue(FS.exists(cachePath))
        }
    }

    func testUnreadableOwnershipInventoryCannotAuthorizeAssociatedDataRemoval() throws {
        try XCTSkipIf(getuid() == 0, "requires regular user permissions")
        let path = try peer("Unreadable", id: "com.example.peer") + "/Contents/Info.plist"
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        let reviewed = try plan()
        XCTAssertFalse(reviewed.ownership?.complete ?? true)
        XCTAssertNotNil(reviewed.blocked)
        XCTAssertTrue(execute(reviewed).removed.isEmpty)
        XCTAssertTrue(FS.exists(cachePath))
    }

    func testPeerNamespaceChangeWithoutDirectoryReplacementRequiresReviewAgain() throws {
        let path = try peer("Peer", id: "org.unrelated.peer")
        let reviewed = try plan()
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.fixture"], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        XCTAssertTrue(execute(reviewed).removed.isEmpty)
        XCTAssertTrue(FS.exists(cachePath)); XCTAssertTrue(FS.exists(appPath))
    }

    func testOlderPlansWithoutOwnershipProofCannotRemoveAssociatedData() throws {
        var reviewed = try plan(removeApp: true)
        reviewed.ownership = nil
        XCTAssertTrue(execute(reviewed).removed.isEmpty)
        XCTAssertTrue(FS.exists(appPath)); XCTAssertTrue(FS.exists(cachePath))
    }

    func outsideCopy(id: String? = "com.example.fixture") throws -> String {
        let path = home + "/Portable/Copy.app"
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        var info = ["CFBundleName": "Copy"]
        info["CFBundleIdentifier"] = id
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        return path
    }
    func running(_ path: String) -> ProcessTable {
        ProcessTable(entries: [AgentProcess(pid: 42, name: "Fixture", executable: path + "/Contents/MacOS/Fixture")])
    }

    func testRunningOutsideCopyKeepsBothIDAndNameDataWhileInstalledBundleCanMove() throws {
        let copy = try outsideCopy()
        let named = home + "/Library/Caches/Fixture"
        try data(named)
        let app = try XCTUnwrap(AppUninstaller.read(appPath))
        let active = running(copy)
        let reviewed = AppUninstaller.plan(app, installed: [app], home: home, processes: active, ownershipDirectories: [home + "/Applications"])
        XCTAssertNil(reviewed.blocked)
        XCTAssertEqual(reviewed.paths, [appPath])
        XCTAssertTrue(reviewed.ownershipKept?.contains(cachePath) == true)
        XCTAssertTrue(reviewed.ownershipKept?.contains(named) == true)
        let result = execute(reviewed, processes: active)
        XCTAssertEqual(result.removed, [appPath])
        XCTAssertTrue(FS.exists(copy)); XCTAssertTrue(FS.exists(cachePath)); XCTAssertTrue(FS.exists(named))
    }

    func testOutsideCopyStartedAfterReviewStopsBothRemovalModesBeforeAnyMove() throws {
        let copy = try outsideCopy()
        for removeApp in [true, false] {
            let result = execute(try plan(removeApp: removeApp), processes: running(copy))
            XCTAssertTrue(result.removed.isEmpty)
            XCTAssertTrue(FS.exists(appPath)); XCTAssertTrue(FS.exists(cachePath))
        }
    }

    func testOutsideCopyAppearingAtMoveBoundaryStopsTheWholeRemainingBatch() throws {
        let copy = try outsideCopy()
        let reviewed = try plan(removeApp: true)
        var reads = 0
        let result = AppUninstaller.uninstall(reviewed, home: home, processes: {
            reads += 1
            return reads == 1 ? self.empty : self.running(copy)
        }, ownershipDirectories: [home + "/Applications"], move: move)
        XCTAssertGreaterThanOrEqual(reads, 2)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.failed.count, reviewed.paths.count)
        XCTAssertTrue(result.failed.values.allSatisfy { $0 == tr("Running app ownership changed; review associated data again") })
        XCTAssertTrue(FS.exists(appPath)); XCTAssertTrue(FS.exists(cachePath))
    }

    func testTargetStartingAtMoveBoundaryDoesNotLeaveDataRemovalRunning() throws {
        let reviewed = try plan(removeApp: true)
        var reads = 0
        let result = AppUninstaller.uninstall(reviewed, home: home, processes: {
            reads += 1
            return reads == 1 ? self.empty : self.running(self.appPath)
        }, ownershipDirectories: [home + "/Applications"], move: move)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.failed.count, reviewed.paths.count)
        XCTAssertTrue(FS.exists(appPath)); XCTAssertTrue(FS.exists(cachePath))
    }

    func testRunningOutsideAppWithUnknownDeclarationCannotAuthorizeDataRemoval() throws {
        let copy = try outsideCopy(id: nil)
        let app = try XCTUnwrap(AppUninstaller.read(appPath))
        let reviewed = AppUninstaller.plan(app, installed: [app], home: home, processes: running(copy), removeApp: false,
                                          ownershipDirectories: [home + "/Applications"])
        XCTAssertNotNil(reviewed.blocked)
        XCTAssertTrue(reviewed.ownership?.issues.contains(copy) == true)
        XCTAssertTrue(execute(reviewed, processes: running(copy)).removed.isEmpty)
    }

    func testRuntimeDiscoveryIncludesNestedAppDeclarationsButNotOrdinarySuiteDuplicates() {
        let directories = ["/Applications", "/Applications/Utilities"]
        let nested = "/Applications/Outer.app/Contents/Helpers/Inner.app"
        let paths = AppOwnershipSnapshot.supplementalPaths(running(nested), directories: directories)
        XCTAssertEqual(paths, [nested])
        XCTAssertFalse(AppOwnershipSnapshot.isDiscovered("/Applications/Outer.app/Inner.app", directories: directories))
        XCTAssertFalse(AppOwnershipSnapshot.isDiscovered("/Applications/Utilities/More/Extra.app", directories: directories))
        XCTAssertTrue(AppOwnershipSnapshot.isDiscovered("/Applications/Suite/Extra.app", directories: directories))
    }

    func testAppSuffixedWrapperWithoutDeclarationIsNotASecondUnknownApp() throws {
        let container = home + "/Portable/com.helper.app"
        let actual = container + "/Actual.app"
        try FileManager.default.createDirectory(atPath: actual + "/Contents", withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.unrelated.helper"], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: actual + "/Contents/Info.plist"))
        let app = try XCTUnwrap(AppUninstaller.read(appPath))
        let reviewed = AppUninstaller.plan(app, installed: [app], home: home, processes: running(actual), removeApp: false,
                                          ownershipDirectories: [home + "/Applications"])
        XCTAssertNil(reviewed.blocked)
        XCTAssertTrue(reviewed.ownership?.extraPaths.contains(actual) == true)
        XCTAssertFalse(reviewed.ownership?.extraPaths.contains(container) == true)
        XCTAssertTrue(reviewed.paths.contains(cachePath))
    }

    func testUnavailableProcessInventoryIsNotAnEmptyVerifiedInventory() throws {
        let unavailable = ProcessTable(entries: [], available: false)
        let app = try XCTUnwrap(AppUninstaller.read(appPath))
        let reviewed = AppUninstaller.plan(app, installed: [app], home: home, processes: unavailable, removeApp: false,
                                          ownershipDirectories: [home + "/Applications"])
        XCTAssertEqual(reviewed.blocked, tr("Could not verify running apps; refresh before removing files"))
        XCTAssertTrue(execute(try plan(), processes: unavailable).removed.isEmpty)
        XCTAssertTrue(FS.exists(appPath)); XCTAssertTrue(FS.exists(cachePath))
    }

    func testProcessInventoryFailureAtMoveBoundaryStopsAllRemainingPaths() throws {
        let reviewed = try plan(removeApp: true)
        var reads = 0
        let result = AppUninstaller.uninstall(reviewed, home: home, processes: {
            reads += 1
            return reads == 1 ? self.empty : ProcessTable(entries: [], available: false)
        }, ownershipDirectories: [home + "/Applications"], move: move)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.failed.count, reviewed.paths.count)
        XCTAssertTrue(result.failed.values.allSatisfy { $0 == tr("Could not verify running apps; refresh before removing files") })
        XCTAssertTrue(FS.exists(appPath)); XCTAssertTrue(FS.exists(cachePath))
    }
}
