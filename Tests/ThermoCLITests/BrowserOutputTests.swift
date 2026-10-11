import XCTest
import CleanKit
@testable import thermo

final class BrowserOutputTests: XCTestCase {
    func testSkippedAndInvalidComparisonsHaveAnExplicitNotice() {
        let sample = ChromeInspector.Snapshot(at: Date(), rows: [])
        var report = ChromeInspector.diagnose(sample)
        XCTAssertNil(PulseCommand.browserComparisonNotice(report))
        report.comparisonSkipped = 2
        XCTAssertNotNil(PulseCommand.browserComparisonNotice(report))
        report.invalidTimestamp = true
        XCTAssertNotNil(PulseCommand.browserComparisonNotice(report))
    }

    func testNestedBrowserReportIsMarkedAsJSONInCSV() {
        struct Nested: Encodable { let comparedPages = 0; let comparisonSkipped = 1 }
        struct Fixture: Encodable { let mode = "devtools"; let report = Nested() }
        let output = Export.pulseCSV(Fixture())
        XCTAssertTrue(output.contains("system,report,"))
        XCTAssertTrue(output.contains("comparisonSkipped"))
        XCTAssertTrue(output.hasSuffix(",JSON"))
    }
}
