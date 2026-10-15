@testable import CleanKit
import Darwin
import Foundation
import XCTest

final class OverviewCompletenessTests: XCTestCase {
    var home = ""
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: home) }

    func testFootprintPreservesCancellationAndMissingPathAsIncomplete() {
        let token = ScanCancellation(); token.cancel()
        XCTAssertTrue(FS.footprint(home, cancellation: token).incomplete)
        XCTAssertTrue(FS.footprint(home + "/missing").incomplete)
        XCTAssertFalse(FS.footprint(home).incomplete)
    }

    func testUnreadableCategoryCountsAttemptsSeparatelyAndKeepsUnknownChildren() throws {
        try XCTSkipIf(getuid() == 0, "requires regular user permissions")
        let known = home + "/known", locked = home + "/locked"
        try FileManager.default.createDirectory(atPath: known, withIntermediateDirectories: true)
        try Data(repeating: 37, count: 4096).write(to: URL(fileURLWithPath: known + "/file"))
        try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked) }
        let spot = SpaceOverview.Spot(id: "fixture", title: "Fixture", paths: [known, locked], children: 1, expand: false)
        let overview = SpaceOverview.measure(home: home, spots: [spot])
        let entry = try XCTUnwrap(overview.entries.first { $0.id == "fixture" })
        XCTAssertEqual(entry.complete, false)
        XCTAssertEqual(entry.measuredLocations, 1)
        XCTAssertEqual(entry.attemptedLocations, 2)
        XCTAssertEqual(entry.totalLocations, 2)
        XCTAssertEqual(entry.effectiveSizeState, .incomplete)
        XCTAssertEqual(entry.children.count, 2, "unknown children must survive the top-child limit")
        XCTAssertEqual(entry.children.first { $0.path == locked }?.effectiveSizeState, .unavailable)
        XCTAssertEqual(overview.incompleteLocations, [locked])
        XCTAssertEqual(overview.entries.first { $0.id == "other" }?.effectiveSizeState, .unavailable)
    }

    func testNonPermissionFailureRemainsIncompleteWithoutSuggestingFullDiskAccess() throws {
        let spot = SpaceOverview.Spot(id: "fixture", title: "Fixture", paths: [home], children: 1, expand: false, reportsDenied: false)
        let overview = SpaceOverview.measure(home: home, spots: [spot], footprint: { _, _ in
            DiskFootprint(allocated: 128, files: 1, newest: nil, denied: false, incomplete: true)
        })
        let entry = try XCTUnwrap(overview.entries.first { $0.id == "fixture" })
        XCTAssertEqual(entry.effectiveSizeState, .incomplete)
        XCTAssertEqual(entry.measuredLocations, 0)
        XCTAssertEqual(entry.attemptedLocations, 1)
        XCTAssertEqual(overview.incompleteLocations, [home])
        XCTAssertEqual(overview.unreadable, [])
        let cache = URL(fileURLWithPath: home + "/cache.json")
        overview.save(to: cache)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testCompleteEmptyAndUnavailableZeroHaveDifferentDisplayStates() throws {
        let spot = SpaceOverview.Spot(id: "fixture", title: "Fixture", paths: [home], children: 1, expand: false)
        let complete = try XCTUnwrap(SpaceOverview.measure(home: home, spots: [spot]).entries.first { $0.id == "fixture" })
        let unknown = try XCTUnwrap(SpaceOverview.measure(home: home, spots: [spot], footprint: { _, _ in
            DiskFootprint(allocated: 0, files: 0, newest: nil, denied: false, incomplete: true)
        }).entries.first { $0.id == "fixture" })
        XCTAssertEqual(complete.effectiveSizeState, .complete)
        XCTAssertEqual(unknown.effectiveSizeState, .unavailable)
        XCTAssertNotEqual(complete.sizeText, unknown.sizeText)
    }

    func testPlanningFailureIsNotTreatedAsAnAbsentOptionalRoot() throws {
        let file = home + "/file"
        try Data([1]).write(to: URL(fileURLWithPath: file))
        let spots: [SpaceOverview.Spot] = [
            .init(id: "missing", title: "Missing", paths: [home + "/missing"], children: 0),
            .init(id: "invalid", title: "Invalid", paths: [file + "/child"], children: 0)
        ]
        let result = SpaceOverview.measure(home: home, spots: spots)
        XCTAssertEqual(result.entries.first { $0.id == "missing" }?.effectiveSizeState, .complete)
        XCTAssertEqual(result.entries.first { $0.id == "invalid" }?.effectiveSizeState, .unavailable)
        XCTAssertEqual(result.incompleteLocations, [file + "/child"])
    }

    func testRuntimeMissingSizesDoNotBecomeCompleteZeros() throws {
        let partial = Data(#"{"a":{"identifier":"a","sizeBytes":100},"b":{"identifier":"b"}}"#.utf8)
        let entry = try XCTUnwrap(SpaceOverview.runtimeEntry(partial))
        XCTAssertEqual(entry.effectiveSizeState, .incomplete)
        XCTAssertEqual(entry.children.first { $0.id == "runtime/b" }?.effectiveSizeState, .unavailable)
        XCTAssertEqual(SpaceOverview.runtimeEntry(Data("{}".utf8))?.effectiveSizeState, .complete)
        XCTAssertNil(SpaceOverview.runtimeEntry(Data(#"{"a":{"identifier":"a","sizeBytes":-1}}"#.utf8)))
        XCTAssertNil(SpaceOverview.runtimeEntry(Data(#"{"a":{"identifier":"a","sizeBytes":9223372036854775807},"b":{"identifier":"b","sizeBytes":1}}"#.utf8)))
    }
}
