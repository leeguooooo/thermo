import XCTest
@testable import CleanKit
@testable import ThermoApp

final class BrowserStateTests: XCTestCase {
    @MainActor func testCloseUpdatesMemoryTotalsAndDuplicates() {
        let rows = (0..<7).map { i in
            ChromeInspector.Target(targetId: "p\(i)", type: "page", url: i < 2 ? "https://example.com/" : "https://example.com/\(i)",
                                   title: "Page \(i)", attached: true, heap: Double(7 - i) * 1_048_576)
        }
        let report = ChromeInspector.diagnose(.init(at: Date(), rows: rows))
        let diagnosis = ChromeInspector.diagnosis(report, app: "Fixture", appMemoryKB: 50_000, gpuKB: nil)
        let result = ChromePagesModel.removingClosedPage(from: diagnosis, url: rows[0].url, title: rows[0].title)
        XCTAssertEqual(result.report?.pages.count, 6)
        XCTAssertEqual(result.report?.pagesHeapMB, report.pagesHeapMB - 7)
        XCTAssertEqual(result.report?.largest.count, 5, "The next largest page replaces the closed one")
        XCTAssertTrue(result.duplicates.isEmpty)
        XCTAssertTrue(result.report?.duplicates.isEmpty == true)
        XCTAssertNil(result.gap, "Pre-close process memory must not be represented as fresh")
    }

    @MainActor func testIdenticalTabsDoNotSubtractAnArbitraryHeap() {
        let rows = [ChromeInspector.Target(targetId: "a", type: "page", url: "https://example.com/", title: "Same", heap: 10 * 1_048_576),
                    ChromeInspector.Target(targetId: "b", type: "page", url: "https://example.com/", title: "Same", heap: 100 * 1_048_576)]
        let report = ChromeInspector.diagnose(.init(at: Date(), rows: rows))
        let diagnosis = ChromeInspector.diagnosis(report, app: "Fixture", appMemoryKB: 200_000, gpuKB: nil)
        let result = ChromePagesModel.removingClosedPage(from: diagnosis, url: rows[0].url, title: "Same")
        XCTAssertEqual(result.report, report)
        XCTAssertNil(result.gap)
    }

    @MainActor func testCloseRemovesTheMatchingTitleAtTheSameAddress() {
        let tabs = [ChromeInspector.Tab(window: 1, index: 0, url: "https://example.com/", title: "Keep"),
                    ChromeInspector.Tab(window: 1, index: 1, url: "https://example.com/", title: "Close"),
                    ChromeInspector.Tab(window: 2, index: 0, url: "https://example.com/", title: "Keep")]
        let diagnosis = ChromeInspector.Diagnosis(app: "Fixture", mode: .tabs, tabs: tabs, duplicates: ChromeInspector.duplicates(tabs))
        let result = ChromePagesModel.removingClosedPage(from: diagnosis, url: tabs[1].url, title: "Close")
        XCTAssertEqual(result.tabs?.map(\.title), ["Keep", "Keep"])
        XCTAssertEqual(result.duplicates.first?.count, 2)
    }

    @MainActor func testNewCheckIsBlockedWhilePageIsClosing() {
        let model = ChromePagesModel(app: "Fixture", appMemoryKB: nil, gpuKB: nil)
        model.closing = "https://example.com/"
        model.start()
        XCTAssertFalse(model.running)
        XCTAssertNil(model.phase)
    }
}
