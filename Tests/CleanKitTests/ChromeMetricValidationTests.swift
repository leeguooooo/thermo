import XCTest
@testable import CleanKit

final class ChromeMetricValidationTests: XCTestCase {
    private func target(_ id: String, heap: Double?, nodes: Double? = 1) -> ChromeInspector.Target {
        .init(targetId: id, type: "page", url: "https://example.test/" + id, title: "Fixture", heap: heap, nodes: nodes, listeners: 1)
    }

    func testInvalidMetricsDoNotCrashOrCountAsMeasuredPages() {
        let sample = ChromeInspector.Snapshot(at: Date(), rows: [
            target("valid", heap: 1024), target("infinite", heap: .infinity),
            target("negative", heap: -1), target("nodes", heap: 1024, nodes: Double.greatestFiniteMagnitude),
            target("nan", heap: 1024, nodes: .nan),
        ])
        let report = ChromeInspector.diagnose(sample)
        XCTAssertEqual(report.pages.map(\.id), ["valid"])
        XCTAssertEqual(report.unmeasured, 4)
        XCTAssertTrue(report.pagesHeapMB.isFinite)
    }

    func testInvalidEarlierCountsAndTimesDoNotProduceGrowthClaims() {
        let now = Date()
        var before = ChromeInspector.Snapshot(at: now.addingTimeInterval(-60), rows: [target("page", heap: 1024, nodes: .infinity)])
        let after = ChromeInspector.Snapshot(at: now, rows: [target("page", heap: 2048)])
        XCTAssertNil(ChromeInspector.diagnose(after, before: before).pages.first?.growth)
        before.at = .infinity
        let report = ChromeInspector.diagnose(after, before: before)
        XCTAssertNil(report.seconds)
        XCTAssertEqual(report.invalidTimestamp, true)
        XCTAssertTrue(report.leaking.isEmpty)
    }

    func testInvalidTimestampAndAggregateCannotOverflowFormatting() {
        var sample = ChromeInspector.Snapshot(at: Date(), rows: [target("page", heap: 1024)])
        sample.at = .infinity
        var report = ChromeInspector.diagnose(sample)
        XCTAssertTrue(report.sampled.timeIntervalSince1970.isFinite)
        report.pagesHeapMB = Double.greatestFiniteMagnitude
        XCTAssertNil(ChromeInspector.gapText(report, appMemoryKB: 1024, gpuKB: nil))
    }

    func testInvalidWaitFailsBeforeBrowserInteraction() async {
        let result = await ChromeInspector.diagnose(app: "Fixture Browser", measure: true, watch: .infinity)
        XCTAssertEqual(result.mode, .unavailable)
        XCTAssertNotNil(result.hint)
    }
}
