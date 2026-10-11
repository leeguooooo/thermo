import XCTest
@testable import CleanKit

final class DiskSpaceObservationTests: XCTestCase {
    func snapshot(_ free: Int64, volume: String = "fixture", at: TimeInterval = 100) -> DiskSpaceSnapshot {
        .init(volumeID: volume, capacityBytes: 1000, availableBytes: free, measuredAt: Date(timeIntervalSince1970: at))
    }
    func testSignedChangeAndUnavailableMeasurements() {
        XCTAssertEqual(DiskSpaceObservation(before: snapshot(100), after: snapshot(150, at: 101)).availableChangeBytes, 50)
        XCTAssertEqual(DiskSpaceObservation(before: snapshot(100), after: snapshot(80, at: 101)).availableChangeBytes, -20)
        XCTAssertEqual(DiskSpaceObservation(before: snapshot(100), after: snapshot(100, at: 101)).availableChangeBytes, 0)
        XCTAssertNil(DiskSpaceObservation(before: snapshot(100), after: snapshot(150, volume: "other", at: 101)).availableChangeBytes)
        XCTAssertNil(DiskSpaceObservation(before: snapshot(100), after: nil).availableChangeBytes)
        XCTAssertNil(DiskSpaceObservation(before: snapshot(100), after: snapshot(150, at: 99)).availableChangeBytes)
    }
    func testNoIncreaseIsNotPresentedAsFreedSpace() {
        L10n.override = .english
        defer { L10n.override = nil }
        let observation = DiskSpaceObservation(before: snapshot(100), after: snapshot(100, at: 101))
        XCTAssertTrue(observation.summary.contains("no increase"))
        XCTAssertTrue(observation.summary.contains("includes other disk activity"))
        XCTAssertFalse(observation.summary.contains("freed"))
    }
    func testLegacyResultsDecodeWithoutObservation() throws {
        let data = Data(#"{"id":"fixture","removed":[],"failed":{},"bytes":123,"trashed":true}"#.utf8)
        let result = try JSONDecoder().decode(CleanResult.self, from: data)
        XCTAssertNil(result.spaceObservation)
        XCTAssertTrue(result.trashed)
        XCTAssertEqual(result.bytes, 123)
    }
    func testDisposableCleanupRecordsLiveSpaceAndInvalidatesOverview() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let dir = home + "/Library/Caches/disposable"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data(repeating: 73, count: 1024 * 1024).write(to: URL(fileURLWithPath: dir + "/payload"))
        let overviewURL = URL(fileURLWithPath: home + "/Library/Caches/dev.thermo/space-overview.json")
        try FileManager.default.createDirectory(at: overviewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old overview".utf8).write(to: overviewURL)
        let item = CleanItem(id: "fixture", category: .system, title: "Disposable", safety: .safe, bytes: 1024 * 1024, paths: [dir])
        let result = Cleaner.clean(item, mode: .permanent, guard: Guard(home: home))
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(result.removed, [dir])
        let observation = try XCTUnwrap(result.spaceObservation)
        XCTAssertNotNil(observation.before)
        XCTAssertNotNil(observation.after)
        XCTAssertNotNil(observation.availableChangeBytes)
        // Other programs write to the same volume; asserting a positive delta would be dishonest.
        XCTAssertFalse(FileManager.default.fileExists(atPath: overviewURL.path))
        let encoded = try JSONEncoder().encode(result)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil((object["spaceObservation"] as? [String: Any])?["availableChangeBytes"])
    }
}
