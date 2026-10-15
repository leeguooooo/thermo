@testable import AgentCore
@testable import CleanKit
import Darwin
import Foundation
import ThermoL10n
import XCTest

final class AppSizeTests: XCTestCase {
    var home = ""
    override func setUpWithError() throws {
        L10n.override = .english
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: home + "/Applications", withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }

    func testUnmeasuredEmptyAndMissingAreDistinctAfterRealMeasurement() throws {
        let path = home + "/Applications/Empty.app"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let app = InstalledApp(path: path, name: "Empty", bundleID: nil)
        XCTAssertEqual(app.bundleSizeState, .unmeasured)
        XCTAssertEqual(app.bundleSizeText, "Not measured")
        let measured = try XCTUnwrap(AppUninstaller.measure([app], home: home).first)
        XCTAssertEqual(measured.bundleSizeState, .complete)
        XCTAssertEqual(measured.bytes, 0)
        XCTAssertNotEqual(measured.bundleSizeText, "Not measured")
        XCTAssertNotEqual(measured.bundleSizeText, "Size unavailable")
        try FileManager.default.removeItem(atPath: path)
        let vanished = try XCTUnwrap(AppUninstaller.measure([app], home: home).first)
        XCTAssertEqual(vanished.bundleSizeState, .unavailable)
        XCTAssertEqual(vanished.bundleSizeText, "Size unavailable")
    }

    func testUnreadableFolderDoesNotBecomeACompleteZero() throws {
        try XCTSkipIf(getuid() == 0, "permissions must be exercised as a regular user")
        let path = home + "/Applications/Locked.app"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: path + "/data"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path) }
        let app = InstalledApp(path: path, name: "Locked", bundleID: nil)
        let measured = try XCTUnwrap(AppUninstaller.measure([app], home: home).first)
        XCTAssertNotEqual(measured.bundleSizeState, .complete)
        XCTAssertNotEqual(measured.bundleSizeText, ByteFormat.string(0))
    }

    func testPartialTotalsRemainLowerBoundsAndLegacyZeroIsUnknown() throws {
        var app = InstalledApp(path: "/fixture.app", name: "Fixture", bundleID: nil)
        app.bytes = 1024; app.sizeState = .complete
        app.leftovers = [AppLeftover(path: "/fixture-data", bytes: 2048, sizeState: .incomplete)]
        XCTAssertEqual(app.totalSizeState, .incomplete)
        XCTAssertTrue(app.totalSizeText.hasPrefix("at least "))
        let legacy = Data(#"{"path":"/fixture.app","name":"Fixture","bytes":0,"leftovers":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(InstalledApp.self, from: legacy)
        XCTAssertEqual(decoded.bundleSizeState, .unmeasured)
        XCTAssertNotEqual(decoded.totalSizeText, ByteFormat.string(0))
        XCTAssertEqual(AppLeftover(path: "/legacy", bytes: 0).effectiveSizeState, .unavailable)
    }

    func testPlanAndJSONPreserveIncompleteAssociatedData() throws {
        let path = home + "/Applications/Fixture.app"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        var app = InstalledApp(path: path, name: "Fixture", bundleID: nil)
        app.sizeState = .complete
        app.leftovers = [AppLeftover(path: home + "/Library/Caches/Fixture", bytes: 100, sizeState: .incomplete)]
        let plan = AppUninstaller.plan(app, installed: [app], home: home, processes: ProcessTable(entries: []))
        XCTAssertEqual(plan.sizeState, .incomplete)
        XCTAssertTrue(plan.sizeText.hasPrefix("at least "))
        let decoded = try JSONDecoder().decode(UninstallPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded.sizeState, .incomplete)
        XCTAssertEqual(decoded.app.leftovers.first?.sizeState, .incomplete)
    }

    func testRemovalKeepsUnknownByteEstimatesInHistory() throws {
        let path = home + "/Applications/Fixture.app"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.Trash", withIntermediateDirectories: true)
        var result = CleanResult(id: "app:fixture", trashed: true)
        AppUninstaller.trash([path], bundleIDs: [], sizes: [path: 0], home: home, processes: { ProcessTable(entries: []) },
            into: &result, incompletePaths: [path], move: { source in
                let destination = URL(fileURLWithPath: self.home + "/.Trash/Fixture.app")
                try FileManager.default.moveItem(atPath: source, toPath: destination.path)
                return destination
            })
        XCTAssertEqual(result.removed, [path])
        XCTAssertEqual(result.bytesIncomplete, true)
        AppUninstaller.finish(result, title: "Fixture", home: home)
        let record = try XCTUnwrap(OperationJournal.read(home: home).first)
        XCTAssertEqual(record.bytesIncomplete, true)
        XCTAssertEqual(record.sizeText, "Size unavailable")
    }

    func testCancelledMeasurementDoesNotPublishAZero() throws {
        let token = ScanCancellation(); token.cancel()
        let app = InstalledApp(path: home + "/Applications/Unknown.app", name: "Unknown", bundleID: nil)
        let result = AppUninstaller.measure([app], home: home, cancellation: token) { _ in XCTFail("must not publish cancelled measurement") }
        XCTAssertEqual(result.first?.bundleSizeState, .unmeasured)
    }

    func testUnreadableOrphanIsVisibleButBlockedEvenBelowSizeThreshold() throws {
        try XCTSkipIf(getuid() == 0, "permissions must be exercised as a regular user")
        let path = home + "/Library/Caches/com.example.gone"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: path + "/data"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path) }
        let found = AppUninstaller.orphans(home: home, known: [], now: Date().addingTimeInterval(40 * 86400), spotlight: { _ in false })
        let blocked = try XCTUnwrap(found.first { $0.bundleID == "com.example.gone" })
        XCTAssertNotNil(blocked.blocked)
        XCTAssertEqual(blocked.sizeState, .unavailable)
    }

    func testUnreadableSubtreeStillMeasuresReadableSiblingsAsALowerBound() throws {
        try XCTSkipIf(getuid() == 0, "permissions must be exercised as a regular user")
        let path = home + "/Applications/Partial.app"
        try FileManager.default.createDirectory(atPath: path + "/Hidden", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: path + "/Readable", withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: URL(fileURLWithPath: path + "/Readable/data"))
        try Data(repeating: 2, count: 4096).write(to: URL(fileURLWithPath: path + "/Hidden/data"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path + "/Hidden")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path + "/Hidden") }
        let expected = FS.size(path + "/Readable/data").allocated
        let size = FS.size(path)
        XCTAssertTrue(size.denied)
        XCTAssertTrue(size.incomplete)
        XCTAssertGreaterThanOrEqual(size.allocated, expected)
        let measured = try XCTUnwrap(AppUninstaller.measure([InstalledApp(path: path, name: "Partial", bundleID: nil)], home: home).first)
        XCTAssertEqual(measured.bundleSizeState, .incomplete)
        XCTAssertTrue(measured.totalSizeText.hasPrefix("at least "))
    }

    func testAppAliasIsNotReportedAsACompleteZeroByteBundle() throws {
        let real = home + "/Applications/Real.app", alias = home + "/Applications/Alias.app"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: URL(fileURLWithPath: real + "/data"))
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: real)
        let measured = try XCTUnwrap(AppUninstaller.measure([InstalledApp(path: alias, name: "Alias", bundleID: nil)], home: home).first)
        XCTAssertEqual(measured.bundleSizeState, .unavailable)
        XCTAssertEqual(measured.bundleSizeText, "Size unavailable")
    }

    func testEveryBundlePublishesBeforeAssociatedDataFinishes() throws {
        let apps = try (0..<6).map { i -> InstalledApp in
            let path = home + "/Applications/Fixture\(i).app"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return InstalledApp(path: path, name: "Fixture\(i)", bundleID: nil)
        }
        let lock = NSLock()
        var phases: [Bool] = []
        let measured = AppUninstaller.measure(apps, home: home) { app in
            lock.lock(); phases.append(app.relatedDataState == .unmeasured); lock.unlock()
        }
        XCTAssertEqual(phases.count, apps.count * 2)
        XCTAssertTrue(phases.prefix(apps.count).allSatisfy { $0 })
        XCTAssertTrue(measured.allSatisfy { $0.relatedDataState == .complete })
    }

    func testBudgetExpiryDoesNotReleaseBlockedPhysicalWorkers() throws {
        let apps = (0..<8).map { InstalledApp(path: home + "/Applications/\($0).app", name: "Fixture\($0)", bundleID: nil) }
        let gate = DispatchSemaphore(value: 0), lock = NSLock()
        var calls = 0
        let sizing: (String, ScanCancellation?) -> TreeSize = { _, _ in
            lock.lock(); calls += 1; lock.unlock()
            _ = gate.wait(timeout: .now() + 5)
            return TreeSize()
        }
        defer { for _ in 0..<16 { gate.signal() } }
        let began = Date()
        let first = AppUninstaller.measureInventory(apps, home: home, cancellation: nil, budget: 0.05, size: sizing, each: { _ in XCTFail("expired work must not publish") })
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
        let second = AppUninstaller.measureInventory(apps, home: home, cancellation: nil, budget: 0.05, size: sizing, each: nil)
        lock.lock(); let actual = calls; lock.unlock()
        XCTAssertGreaterThan(actual, 0)
        XCTAssertLessThanOrEqual(actual, 4, "a second scan must not get extra physical workers")
        XCTAssertTrue(first.allSatisfy { $0.bundleSizeState == .unmeasured })
        XCTAssertTrue(second.allSatisfy { $0.bundleSizeState == .unmeasured })
    }
}
