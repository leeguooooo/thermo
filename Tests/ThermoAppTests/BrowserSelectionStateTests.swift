import XCTest
@testable import CleanKit
@testable import ThermoApp

private final class PageActionFixture: @unchecked Sendable {
    let lock = NSLock()
    var submitted: [[String]] = []
    var reads = 0
    let initial: [ChromeInspector.Tab]
    let remaining: [ChromeInspector.Tab]?
    init(initial: [ChromeInspector.Tab], remaining: [ChromeInspector.Tab]?) { self.initial = initial; self.remaining = remaining }
    var actions: BrowserPageActions {
        .init(tabs: { _ in self.remaining }, close: { tabs, _ in
            self.lock.lock(); self.submitted.append(tabs.map(\.selectionID)); self.lock.unlock()
            return tabs.map { .init(id: $0.selectionID, status: $0.selectionID == self.initial.first?.selectionID ? .closed : .changed) }
        }, reading: { _ in
            self.lock.lock(); let count = self.reads; self.reads += 1; self.lock.unlock()
            let pulse = MachinePulse(load1: 8, load5: 8, cores: 8, thermal: .nominal, memory: .warning,
                                     swapUsedMB: 12_000, hogs: [], sampled: Date(timeIntervalSince1970: count == 0 ? 100 : 105))
            return .init(pulse: pulse, browserMemoryKB: count == 0 ? 4_000_000 : 3_000_000)
        }, wait: {})
    }
}

final class BrowserSelectionStateTests: XCTestCase {
    func tabs() -> [ChromeInspector.Tab] {
        let process = ProcessIdentity(pid: 42, uid: 501, started: Date(timeIntervalSince1970: 100), executable: "/fixture/browser")
        return (0..<3).map { .init(window: 1, index: $0 + 1, url: "https://example.test/", title: "Same", browserID: "t\($0)", active: $0 == 0, browserProcess: process) }
    }
    @MainActor func finish(_ model: ChromePagesModel) async throws {
        let deadline = Date().addingTimeInterval(3)
        while model.closing != nil, Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertNil(model.closing)
    }
    @MainActor func testRecommendationSelectionDoesNotCloseOrSelectCurrentPage() {
        let tabs = tabs(); let fixture = PageActionFixture(initial: tabs, remaining: tabs)
        let model = ChromePagesModel(app: "Fixture", appMemoryKB: nil, gpuKB: nil, actions: fixture.actions)
        model.accept(.init(app: "Fixture", mode: .tabs, tabs: tabs, duplicates: []), tabs: tabs)
        XCTAssertTrue(model.selected.isEmpty)
        XCTAssertEqual(model.pages.count, 3)
        model.selectRecommended()
        XCTAssertEqual(model.selected, Set(tabs.dropFirst().map(\.selectionID)))
        XCTAssertTrue(fixture.submitted.isEmpty, "recommendations only change checkboxes")
    }
    @MainActor func testConfirmedPlanDoesNotExpandAndPartialFailuresStaySelected() async throws {
        let tabs = tabs(); let fixture = PageActionFixture(initial: tabs, remaining: Array(tabs.dropFirst()))
        let model = ChromePagesModel(app: "Fixture", appMemoryKB: nil, gpuKB: nil, actions: fixture.actions)
        model.accept(.init(app: "Fixture", mode: .tabs, tabs: tabs, duplicates: []), tabs: tabs)
        model.selected = Set(tabs.prefix(2).map(\.selectionID))
        let plan = model.selectedPages.map(\.tab)
        model.selected.insert(tabs[2].selectionID)
        model.close(plan)
        XCTAssertTrue(model.busy)
        model.selectRecommended()
        try await finish(model)
        XCTAssertEqual(fixture.submitted, [plan.map(\.selectionID)])
        XCTAssertEqual(model.selected, Set(tabs.dropFirst().map(\.selectionID)))
        XCTAssertEqual(model.closeReview?.closed, 1)
        XCTAssertEqual(model.closeReview?.verified, 1)
        XCTAssertEqual(model.closeReview?.skipped, 1)
        XCTAssertEqual(model.closeReview?.after.pulse.memory, .warning)
        XCTAssertFalse(model.inventoryStale)
        XCTAssertFalse(model.resultsStale, "a tab-only inventory contains no old per-page memory figures")
        XCTAssertEqual(model.appMemoryKB, 3_000_000)
    }
    @MainActor func testFailedInventoryRecheckDisablesSelectionUntilRefresh() async throws {
        let tabs = tabs(); let fixture = PageActionFixture(initial: tabs, remaining: nil)
        let model = ChromePagesModel(app: "Fixture", appMemoryKB: nil, gpuKB: nil, actions: fixture.actions)
        model.accept(.init(app: "Fixture", mode: .tabs, tabs: tabs, duplicates: []), tabs: tabs)
        model.selected = [tabs[1].selectionID]
        model.close([tabs[1]])
        try await finish(model)
        XCTAssertTrue(model.inventoryStale)
        XCTAssertNil(model.closeReview?.verified)
        XCTAssertFalse(model.canCloseSelected)
        XCTAssertTrue(model.recommendedPages.isEmpty)
        model.accept(.init(app: "Fixture", mode: .tabs, tabs: tabs, duplicates: []), tabs: tabs)
        XCTAssertFalse(model.inventoryStale)
    }
    @MainActor func testAllTabsRemainVisibleBeyondTheFiveLargestMeasuredPages() {
        let tabs = tabs() + (3..<9).map { ChromeInspector.Tab(window: 2, index: $0, url: "https://example.test/\($0)", title: "Page \($0)") }
        let rows = tabs.prefix(7).enumerated().map { ChromeInspector.Target(targetId: "p\($0.offset)", type: "page", url: $0.element.url, title: $0.element.title, heap: 1_000_000) }
        let report = ChromeInspector.diagnose(.init(at: Date(), rows: rows))
        let model = ChromePagesModel(app: "Fixture", appMemoryKB: nil, gpuKB: nil)
        model.accept(ChromeInspector.diagnosis(report, app: "Fixture", appMemoryKB: nil, gpuKB: nil), tabs: tabs)
        XCTAssertEqual(report.largest.count, 5)
        XCTAssertEqual(model.pages.count, 9)
    }
}
