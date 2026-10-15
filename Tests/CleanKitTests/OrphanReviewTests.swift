@testable import AgentCore
@testable import CleanKit
import Foundation
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
        try XCTUnwrap(AppUninstaller.reviewedOrphans(home: home, known: [], now: later, spotlight: { _ in false },
            processes: processes, directories: directories).first { $0.bundleID == id })
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
}
