import XCTest
@testable import CleanKit

final class DiskSpaceSnapshotTests: XCTestCase {
    /// The live reading carries the purgeable gap, so the overview can say why Finder's number is larger.
    func testLiveReadingIncludesPurgeableGap() throws {
        let snapshot = try XCTUnwrap(DiskSpaceSnapshot.measure(path: NSTemporaryDirectory()))
        let purgeable = try XCTUnwrap(snapshot.purgeableBytes)
        XCTAssertGreaterThanOrEqual(purgeable, 0)
        XCTAssertLessThanOrEqual(snapshot.availableBytes + purgeable, snapshot.capacityBytes)
    }

    /// Older saved snapshots without the field still decode.
    func testDecodesWithoutPurgeable() throws {
        let json = #"{"volumeID":"v","capacityBytes":100,"availableBytes":10,"measuredAt":0}"#
        let snapshot = try JSONDecoder().decode(DiskSpaceSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.purgeableBytes)
    }
}
