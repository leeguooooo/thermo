@testable import AgentCore
@testable import CleanKit
import Foundation
import Darwin
import XCTest

final class OrphanReviewTests: XCTestCase {
    var home = ""
    let id = "com.example.orphan-review"
    var later: Date { Date().addingTimeInterval(40 * 86400) }
    var directories: [String] { [home + "/Applications"] }
    var cache: String { home + "/Library/Caches/" + id }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: directories[0], withIntermediateDirectories: true)
        try write(cache)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }
    func write(_ path: String, bytes: String = "original") throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: URL(fileURLWithPath: path))
    }
    func install(_ bundleID: String) throws {
        let path = directories[0] + "/Returned.app/Contents/Info.plist"
        let info = ["CFBundleIdentifier": bundleID, "CFBundleName": "Returned", "CFBundlePackageType": "APPL"]
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: URL(fileURLWithPath: path))
    }
    func review(processes: ProcessTable = .init(entries: [])) throws -> OrphanData {
        let now = later
        let found = try XCTUnwrap(AppUninstaller.reviewedOrphans(home: home, known: [], now: now, spotlight: { _ in false },
            processes: processes, directories: directories).first { $0.bundleID == id })
        return try XCTUnwrap(AppUninstaller.reviewOrphans([found], home: home, now: now, processes: processes,
            directories: directories, spotlight: { _ in .absent }).first)
    }
    func remove(_ data: OrphanData, processes: @escaping () -> ProcessTable = { .init(entries: []) },
                afterMove: () throws -> Void = {}) throws -> CleanResult {
        try XCTUnwrap(AppUninstaller.removeOrphans([data], home: home, installed: [], processes: processes, spotlight: { _ in false },
            directories: directories, now: later, move: { path in
                let target = self.home + "/.Trash/" + UUID().uuidString
                try FileManager.default.createDirectory(atPath: self.home + "/.Trash", withIntermediateDirectories: true)
                try FileManager.default.moveItem(atPath: path, toPath: target)
                try afterMove()
                return URL(fileURLWithPath: target)
            }).first)
    }

    func makeDeepDirectory(_ path: String) throws -> URL {
        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        let file = URL(fileURLWithPath: path + "/Nested/Deeper/resource")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("before".utf8).write(to: file)
        return file
    }
    func changeDeepResource(_ file: URL) throws {
        var before = stat()
        XCTAssertEqual(lstat(file.path, &before), 0)
        try Data("after!".utf8).write(to: file)
        var times = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, file.path, &times, 0), 0)
    }

    func testDeepOrphanChangeAtFinalProcessCheckKeepsDirectory() throws {
        let file = try makeDeepDirectory(cache)
        let data = try review()
        XCTAssertNil(data.blocked)
        var reads = 0
        let result = try remove(data, processes: {
            reads += 1
            if reads == 3 { try! self.changeDeepResource(file) }
            return .init(entries: [])
        })
        XCTAssertGreaterThanOrEqual(reads, 3)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertFalse(result.failed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache))
        if let batch = result.trashBatchID { _ = try TrashBatches.restore(id: batch, home: home) }
        XCTAssertEqual(try Data(contentsOf: file), Data("after!".utf8))
    }

    func testDeepOrphanChangeAfterFirstMoveKeepsLaterDirectory() throws {
        _ = try makeDeepDirectory(cache)
        let logs = home + "/Library/Logs/" + id
        _ = try makeDeepDirectory(logs)
        let data = try review()
        XCTAssertNil(data.blocked)
        XCTAssertEqual(data.items.count, 2)
        let first = try XCTUnwrap(data.items.first?.path)
        let later = try XCTUnwrap(data.items.last?.path)
        let changed = URL(fileURLWithPath: later + "/Nested/Deeper/resource")
        var moves = 0
        let result = try remove(data, afterMove: {
            moves += 1
            if moves == 1 { try self.changeDeepResource(changed) }
        })
        XCTAssertEqual(result.removed, [first])
        XCTAssertFalse(result.failed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: later))
        let restored = try TrashBatches.restore(id: XCTUnwrap(result.trashBatchID), home: home)
        XCTAssertEqual(restored.items.count, 1)
        XCTAssertEqual(restored.items.map(\.status), ["restored"])
        XCTAssertEqual(try Data(contentsOf: changed), Data("after!".utf8))
    }

    func testDirectoryScanWithoutSelectedReviewCannotAuthorizeRemoval() throws {
        _ = try makeDeepDirectory(cache)
        let scanned = try XCTUnwrap(report().items.first { $0.bundleID == id })
        XCTAssertNil(scanned.dataTreeIdentities, "Discovery must not perform the selected-directory review")
        let result = try remove(scanned)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertFalse(result.failed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache))
    }

    func testPreparationRejectsActivityAppearingAfterSizeAndAgeCheck() throws {
        let file = try makeDeepDirectory(cache)
        let now = later
        let scanned = try XCTUnwrap(AppUninstaller.reviewedOrphanReport(home: home, known: [], now: now,
            spotlight: { _ in .absent }, processes: .init(entries: []), directories: directories).items.first)
        let selected = AppUninstaller.reviewOrphans([scanned], home: home, now: now, processes: .init(entries: []),
            directories: directories, spotlight: { _ in
                // This callback occurs after the size walk and its age decision.
                try! FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-AppUninstaller.orphanAge + 1)], ofItemAtPath: file.path)
                return .absent
            })
        XCTAssertNotNil(selected.first?.blocked)
        XCTAssertNil(selected.first?.dataTreeIdentities?[cache])
        XCTAssertTrue(try remove(XCTUnwrap(selected.first)).removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache))
    }

    func testSelectedReviewDoesNotQueryUnselectedResidualGroups() throws {
        _ = try makeDeepDirectory(cache)
        let other = home + "/Library/Caches/com.example.unselected"
        _ = try makeDeepDirectory(other)
        let scanned = try XCTUnwrap(report().items.first { $0.bundleID == id })
        var queried: [String] = []
        let selected = AppUninstaller.reviewOrphans([scanned], home: home, now: later, processes: .init(entries: []),
            directories: directories, spotlight: { value in queried.append(value); return .absent })
        XCTAssertEqual(queried, [id])
        XCTAssertEqual(selected.map(\.bundleID), [id])
        XCTAssertNil(selected.first?.blocked)
        XCTAssertNotNil(selected.first?.dataTreeIdentities?[cache])
        XCTAssertTrue(FileManager.default.fileExists(atPath: other))
    }

    func testUnchangedReviewMovesOnlyOwnedDataAndRecordsRecovery() throws {
        let data = try review()
        XCTAssertNil(data.blocked)
        let result = try remove(data)
        XCTAssertEqual(result.removed, [cache]); XCTAssertTrue(result.failed.isEmpty)
        let batch = try TrashBatches.load(try XCTUnwrap(result.trashBatchID), home: home)
        XCTAssertEqual(batch.entries.map(\.original), [cache])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: batch.entries[0].destination)), Data("original".utf8))
    }
    func testSamePathReplacementAfterReviewIsPreserved() throws {
        let data = try review()
        try FileManager.default.removeItem(atPath: cache)
        try write(cache, bytes: "replacement")
        let result = try remove(data)
        XCTAssertTrue(result.removed.isEmpty); XCTAssertFalse(result.failed.isEmpty)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: cache)), Data("replacement".utf8))
    }
    func testReinstalledAppIsFoundDespiteStaleInstalledArgument() throws {
        let data = try review()
        try install(id)
        let result = try remove(data)
        XCTAssertTrue(result.removed.isEmpty); XCTAssertFalse(result.failed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache))
    }
    func testChangedOwnershipInventoryRequiresAnotherReview() throws {
        let data = try review()
        try install("com.example.other")
        let result = try remove(data)
        XCTAssertTrue(result.removed.isEmpty); XCTAssertFalse(result.failed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache))
    }
    func testUnavailableProcessInventoryCannotAuthorizeOrphanRemoval() throws {
        let unavailable = ProcessTable(entries: [], available: false)
        XCTAssertNotNil(try review(processes: unavailable).blocked)
        let result = try remove(review(), processes: { unavailable })
        XCTAssertTrue(result.removed.isEmpty); XCTAssertFalse(result.failed.isEmpty)
    }
    func testAppReturningBetweenMovesPreservesRemainingData() throws {
        let log = home + "/Library/Logs/" + id
        try write(log)
        let data = try review()
        var moves = 0
        let result = try remove(data, afterMove: { moves += 1; try self.install(self.id) })
        XCTAssertEqual(moves, 1)
        XCTAssertEqual(result.removed.count, 1); XCTAssertFalse(result.failed.isEmpty)
        XCTAssertEqual([cache, log].filter { FileManager.default.fileExists(atPath: $0) }.count, 1)
    }
    func testLegacyReviewWithoutIdentityCannotAuthorizeRemoval() throws {
        var data = try review(); data.dataIdentities = nil; data.ownership = nil
        let decoded = try JSONDecoder().decode(OrphanData.self, from: JSONEncoder().encode(data))
        let result = try remove(decoded)
        XCTAssertTrue(result.removed.isEmpty); XCTAssertFalse(result.failed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache))
    }
    func testUnreadableOwnershipDirectoryBlocksCandidates() throws {
        let file = home + "/unreadable-root"
        try write(file)
        let found = AppUninstaller.reviewedOrphans(home: home, known: [], now: later, spotlight: { _ in false },
            processes: .init(entries: []), directories: [file])
        XCTAssertEqual(found.count, 1); XCTAssertNotNil(found.first?.blocked)
    }

    func report(spotlight: (String) -> OrphanAppPresence = { _ in .absent }, cancellation: ScanCancellation? = nil) -> OrphanScanReport {
        AppUninstaller.reviewedOrphanReport(home: home, known: [], now: later, spotlight: spotlight,
            cancellation: cancellation, processes: .init(entries: []), directories: directories)
    }
    func testInvalidWhitelistMakesResidualReportIncompleteAndBlocksCandidates() throws {
        try write(Whitelist.url(home: home).path, bytes: "relative/protected-path\n")
        let result = report()
        XCTAssertFalse(result.complete); XCTAssertFalse(result.issues.isEmpty)
        XCTAssertEqual(result.items.count, 1); XCTAssertNotNil(result.items.first?.blocked)
    }
    func testMissingOptionalRootsAreACompleteScanRatherThanReadErrors() {
        let result = report(spotlight: { _ in .present })
        XCTAssertTrue(result.complete); XCTAssertTrue(result.issues.isEmpty); XCTAssertTrue(result.items.isEmpty)
    }
    func testInvalidLibraryRootCannotBecomeACompleteEmptyResult() throws {
        try FileManager.default.removeItem(atPath: home + "/Library/Caches")
        try write(home + "/Library/Caches")
        let result = report()
        XCTAssertFalse(result.complete); XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.path == home + "/Library/Caches" })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        XCTAssertEqual(json["complete"] as? Bool, false)
    }
    func testEmptyResultStillReportsUnknownApplicationOwnership() throws {
        try FileManager.default.removeItem(atPath: cache)
        try FileManager.default.removeItem(atPath: directories[0])
        try write(directories[0])
        let result = report()
        XCTAssertTrue(result.items.isEmpty); XCTAssertFalse(result.complete)
        XCTAssertTrue(result.issues.contains { $0.path == directories[0] })
    }
    func testUnavailableSpotlightDoesNotConfirmAbsenceOrAnEmptyScan() {
        let result = report(spotlight: { _ in .unavailable })
        XCTAssertTrue(result.items.isEmpty); XCTAssertFalse(result.complete)
        XCTAssertTrue(result.issues.contains { $0.message.contains("Spotlight") })
    }
    func testPrecancelledReportIsIncompleteAndDoesNotStartQueries() {
        let token = ScanCancellation(); token.cancel()
        let result = report(spotlight: { _ in XCTFail("Cancelled scan must not query Spotlight"); return .absent }, cancellation: token)
        XCTAssertTrue(result.cancelled); XCTAssertFalse(result.complete)
    }
    func testCancellationDuringAQueryRemainsVisibleInReport() {
        let token = ScanCancellation()
        let result = report(spotlight: { _ in token.cancel(); return .absent }, cancellation: token)
        XCTAssertTrue(result.cancelled); XCTAssertFalse(result.complete)
    }
    func testIncompleteMeasurementIsReportedAlongsideTheBlockedCandidate() throws {
        try XCTSkipIf(getuid() == 0, "requires ordinary user permissions")
        try FileManager.default.removeItem(atPath: cache)
        try write(cache + "/nested/file")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: cache + "/nested")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache + "/nested") }
        let result = report()
        XCTAssertFalse(result.complete); XCTAssertNotNil(result.items.first?.blocked)
        XCTAssertTrue(result.issues.contains { $0.path == cache && $0.message.contains("measurement") })
    }
    func testFailedTimedOutTruncatedAndCancelledSpotlightResultsStayUnknown() {
        for result in [CommandRunner.Result(status: 1, output: "", timedOut: false, cancelled: false),
                       .init(status: 0, output: "", timedOut: true, cancelled: false),
                       .init(status: 0, output: "", timedOut: false, cancelled: true),
                       .init(status: 0, output: "", timedOut: false, cancelled: false, truncated: true)] {
            XCTAssertEqual(AppUninstaller.spotlightPresence(id, query: { _ in result }), .unavailable)
        }
        XCTAssertEqual(AppUninstaller.spotlightPresence(id, query: { _ in .init(status: 0, output: "\n", timedOut: false, cancelled: false) }), .absent)
        XCTAssertEqual(AppUninstaller.spotlightPresence(id, query: { _ in .init(status: 0, output: "/Applications/Existing.app\n", timedOut: false, cancelled: false) }), .present)
    }
}
