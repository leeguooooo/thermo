@testable import CleanKit
import Darwin
import Foundation
import XCTest

final class DuplicateScanReportTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func file(_ name: String) throws -> String {
        let path = root.appendingPathComponent(name)
        try Data(repeating: 42, count: 4096).write(to: path); return path.path
    }
    func testExplicitMissingRootIsIncompleteInsteadOfConfirmedEmpty() {
        let path = root.appendingPathComponent("missing").path
        let report = Duplicates.scan(in: [path])
        XCTAssertFalse(report.complete); XCTAssertFalse(report.cancelled)
        XCTAssertTrue(report.groups.isEmpty); XCTAssertEqual(report.issues.map(\.path), [path])
    }
    func testUnreadableDirectoryKeepsVerifiedGroupsButReportsIncomplete() throws {
        try XCTSkipIf(geteuid() == 0, "root can read the permission fixture")
        _ = try file("a"); _ = try file("b")
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(locked.path, 0), 0); defer { chmod(locked.path, 0o700) }
        let report = Duplicates.scan(in: [root.path], minimum: 1)
        XCTAssertFalse(report.complete); XCTAssertEqual(report.groups.count, 1)
        XCTAssertTrue(report.issues.contains { $0.path == locked.path })
    }
    func testChangedCandidateDoesNotHideVerifiedGroupOrClaimComplete() throws {
        let a = try file("a"), b = try file("b"), c = try file("c")
        let report = Duplicates.scan(in: [root.path], minimum: 1) { _ in
            try? Data(repeating: 43, count: 4096).write(to: URL(fileURLWithPath: c))
        }
        XCTAssertFalse(report.complete); XCTAssertEqual(report.groups.count, 1)
        XCTAssertEqual(Set(report.groups.first?.paths ?? []), Set([a, b]))
        XCTAssertTrue(report.issues.contains { $0.path == c })
    }
    func testCancellationIsNotACompleteEmptyScan() {
        let token = ScanCancellation(); token.cancel()
        let report = Duplicates.scan(in: [root.path], cancellation: token)
        XCTAssertFalse(report.complete); XCTAssertTrue(report.cancelled); XCTAssertTrue(report.groups.isEmpty)
    }
    func testIssueDetailsAreBoundedWithoutLosingIncompleteStatus() {
        let roots = (0..<140).map { root.appendingPathComponent("missing-\($0)").path }
        let report = Duplicates.scan(in: roots)
        XCTAssertFalse(report.complete); XCTAssertEqual(report.issues.count, 128); XCTAssertEqual(report.omittedIssueCount, 12)
    }
    func testVerifiedEmptyAndDefaultAbsentFoldersStayDistinctFromReadFailure() {
        let report = Duplicates.scan(in: [root.path])
        XCTAssertTrue(report.complete); XCTAssertTrue(report.groups.isEmpty); XCTAssertTrue(report.issues.isEmpty)
        XCTAssertTrue(Duplicates.defaultRoots(home: root.path).isEmpty)
        let missingHome = root.appendingPathComponent("absent-home").path
        XCTAssertEqual(Duplicates.defaultRoots(home: missingHome), [missingHome])
    }
    func testDirectoryChangedAfterListingIsReported() throws {
        for n in 0..<500 { try Data([UInt8(n % 255)]).write(to: root.appendingPathComponent("\(n)")) }
        let report = Duplicates.scan(in: [root.path], minimum: 1) { progress in
            if progress.total == 0 { try? Data("arrived after listing".utf8).write(to: self.root.appendingPathComponent("late")) }
        }
        XCTAssertFalse(report.complete)
        XCTAssertTrue(report.issues.contains { $0.path == root.path })
    }
}
