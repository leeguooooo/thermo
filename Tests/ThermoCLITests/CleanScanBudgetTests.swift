import XCTest
import CleanKit
@testable import thermo

final class CleanScanBudgetTests: XCTestCase {
    func testBudgetParsesPositiveSecondsAndRejectsInvalidValues() throws {
        XCTAssertEqual(try Args(["clean", "overview", "--budget", "2s"]).double("budget"), 2)
        XCTAssertThrowsError(try CleanCommand.budget(Args(["--budget", "1e308"])))
        for value in ["0", "-1", "nan", "invalid"] {
            XCTAssertThrowsError(try Args(["clean", "--budget", value]).double("budget"))
        }
    }
    func testDeadlineCancelsOnlyItsOwnScanToken() {
        let token = ScanCancellation()
        let unrelated = ScanCancellation()
        let deadline = CleanCommand.deadline(after: 0.05, cancellation: token)
        let done = expectation(description: "budget expires")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(token.isCancelled)
        XCTAssertFalse(unrelated.isCancelled)
        deadline?.cancel()
    }
}
