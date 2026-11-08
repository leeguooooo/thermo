import XCTest
@testable import ThermoApp

final class CleanupProtectionsLayoutTests: XCTestCase {
    @MainActor func testSheetFitsShortListsAndCapsLongOnes() {
        let three = CleanupProtectionsView.height(rows: 3, rejected: 0, banners: 0)
        XCTAssertLessThan(three, 460, "three rows must not sit in a 460 pt sheet")
        XCTAssertGreaterThanOrEqual(CleanupProtectionsView.height(rows: 0, rejected: 0, banners: 0), 240)
        XCTAssertEqual(CleanupProtectionsView.height(rows: 40, rejected: 0, banners: 0), 460, "long lists scroll inside the cap")
        XCTAssertGreaterThan(CleanupProtectionsView.height(rows: 3, rejected: 1, banners: 1), three)
    }
}
