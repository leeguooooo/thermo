import XCTest
@testable import AgentDiagnosticsFeature

final class AgentPresentationTests:XCTestCase {
    @MainActor func testDiagnosticsCannotScanDuringBatchFix() {
        let scanner = AgentScanner()
        scanner.batch = AgentScanner.Batch(total: 2)
        XCTAssertTrue(scanner.busy)
        scanner.scan()
        XCTAssertFalse(scanner.scanning)
        scanner.batch?.finished = true
        XCTAssertFalse(scanner.busy)
    }
}
