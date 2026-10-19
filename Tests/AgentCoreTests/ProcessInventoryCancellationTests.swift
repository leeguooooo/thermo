import XCTest
@testable import AgentCore

final class ProcessInventoryCancellationTests: XCTestCase {
    func testPreCancelledInventoryCannotLookLikeAnEmptySuccessfulInventory() {
        let table = ProcessTable.current(cancelled: { true })
        XCTAssertFalse(table.available)
        XCTAssertFalse(table.inventoryComplete)
        XCTAssertTrue(table.entries.isEmpty)
    }

    func testCancellationDuringEnumerationDiscardsThePartialInventory() {
        var checks = 0
        let table = ProcessTable.current(.init(uid: nil, cpu: false), cancelled: {
            checks += 1
            return checks >= 3
        })
        XCTAssertGreaterThanOrEqual(checks, 3)
        XCTAssertFalse(table.available)
        XCTAssertFalse(table.inventoryComplete)
        XCTAssertTrue(table.includesAllUsers)
        XCTAssertTrue(table.entries.isEmpty)
    }
}
