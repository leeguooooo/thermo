import XCTest
import AgentCore
@testable import CleanKit
@testable import ThermoApp

final class TabWorkspaceUXTests: XCTestCase {
    func page(_ id: Int, window: Int = 1, protected: String? = nil) -> TabWorkspace.Page {
        let identity = ProcessIdentity(pid: 123456, uid: 501, started: Date(timeIntervalSince1970: 1), executable: "/fixture/chrome")
        let tab = ChromeInspector.Tab(window: window, index: id, url: "https://example.test/\(id)", title: "Page \(id)",
                                       browserID: String(id), active: protected == "Current tab", browserProcess: identity)
        return TabWorkspace.Page(tab: tab, group: "example.test", protectedReason: protected)
    }
    @MainActor func testArchiveReviewFreezesEligiblePagesAndName() throws {
        var pages = [page(1, protected: "Current tab"), page(2), page(3, protected: "Playing audio")]
        let plan = try XCTUnwrap(TabWorkspaceView.archivePlan(pages, name: "  Read later  "))
        XCTAssertEqual(plan.pages.map(\.id), [pages[1].id])
        XCTAssertEqual(plan.name, "Read later")
        pages.append(page(4)); pages[1].tab.active = true
        XCTAssertEqual(plan.pages.count, 1)
        XCTAssertEqual(plan.pages[0].tab.active, false, "confirmation is the captured plan, not an expanded live selection")
        XCTAssertNil(TabWorkspaceView.archivePlan([page(1, protected: "Current tab")], name: "anything"))
    }
    @MainActor func testChangingScopeClearsSelectionAndChangesCandidates() {
        let pages = [page(1, protected: "Current tab"), page(2), page(3, window: 2)]
        let preview = TabWorkspaceModel.Preview(inventory: .init(app: "Fixture", generated: Date(), pages: pages), saved: [])
        let model = TabWorkspaceModel(app: "Fixture", preview: preview)
        model.selected = [pages[1].id]
        model.selectWindow(2)
        XCTAssertTrue(model.selected.isEmpty)
        XCTAssertEqual(model.candidates.map(\.id), [pages[2].id])
        model.selected = [pages[2].id]; model.selectAllWindows(true)
        XCTAssertTrue(model.selected.isEmpty)
        XCTAssertEqual(model.candidates.count, 2)
    }
    @MainActor func testReadOnlyPreviewDoesNotStartBrowserActions() {
        let pages = [page(1)]
        let record = TabWorkspace.Archive(name: "Fixture", app: "Fixture", entries: [])
        let preview = TabWorkspaceModel.Preview(inventory: .init(app: "Fixture", generated: Date(), pages: pages), saved: [record])
        let model = TabWorkspaceModel(app: "Fixture", preview: preview)
        model.selected = [pages[0].id]
        model.refresh(); model.group("Do not write"); model.archive(pages, name: "Do not close"); model.restore(record)
        XCTAssertTrue(model.isPreview)
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.pages, pages)
        XCTAssertNil(model.notice)
    }
}
