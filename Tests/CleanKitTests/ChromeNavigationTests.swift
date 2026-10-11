import XCTest
@testable import CleanKit

final class ChromeNavigationTests: XCTestCase {
    private func target(url: String = "https://example.test/page", navigation: Double? = 100, heap: Double) -> ChromeInspector.Target {
        .init(targetId: "fixture", type: "page", url: url, title: "Fixture", heap: heap, nodes: 100, listeners: 10, navigationStart: navigation)
    }

    func testNavigationAndSameURLReloadDoNotBecomeLeaks() {
        let now = Date()
        let before = ChromeInspector.Snapshot(at: now.addingTimeInterval(-60), rows: [target(heap: 10 * 1048576)])
        for current in [target(url: "https://example.test/other", heap: 50 * 1048576), target(navigation: 150, heap: 50 * 1048576)] {
            let report = ChromeInspector.diagnose(.init(at: now, rows: [current]), before: before)
            XCTAssertTrue(report.leaking.isEmpty)
            XCTAssertNil(report.pages.first?.growth)
            XCTAssertEqual(report.comparedPages, 0)
            XCTAssertEqual(report.comparisonSkipped, 1)
        }
        let unchanged = ChromeInspector.diagnose(.init(at: now, rows: [target(heap: 50 * 1048576)]), before: before)
        XCTAssertNotNil(unchanged.pages.first?.growth)
        XCTAssertEqual(unchanged.comparedPages, 1)
    }

    func testOldPayloadsKeepURLBasedComparisonButMixedIdentityIsUnknown() {
        let current = target(navigation: nil, heap: 1048576)
        XCTAssertTrue(ChromeInspector.sameDocument(current, current))
        XCTAssertFalse(ChromeInspector.sameDocument(current, target(heap: 1048576)))
    }

    func testLargeNodeDecreaseDoesNotImplyStablePageListenerLeak() {
        let growth = ChromeInspector.Growth(seconds: 60, heapMB: 0, nodes: -1000, listeners: 500)
        XCTAssertNil(ChromeInspector.leak(growth, .init()))
    }
}
