@testable import CleanKit
import Foundation
import XCTest

final class LastOpenedFilterTests: XCTestCase {
    func testUnknownLastOpenedCannotEstablishInactivity() {
        XCTAssertFalse(SpaceLens.notOpened(since: Date(), lastOpened: nil))
        XCTAssertFalse(SpaceLens.notOpened(since: Date(), lastOpened: Date(timeIntervalSinceReferenceDate: .nan)))
        XCTAssertFalse(SpaceLens.notOpened(since: Date(), lastOpened: Date(timeIntervalSinceReferenceDate: -.infinity)))
    }
    func testKnownOpeningMustBeStrictlyOlderThanTheCutoff() {
        let cutoff = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(SpaceLens.notOpened(since: cutoff, lastOpened: cutoff.addingTimeInterval(-1)))
        XCTAssertFalse(SpaceLens.notOpened(since: cutoff, lastOpened: cutoff))
        XCTAssertFalse(SpaceLens.notOpened(since: cutoff, lastOpened: cutoff.addingTimeInterval(1)))
    }
}
