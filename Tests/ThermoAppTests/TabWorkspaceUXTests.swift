import XCTest
import AgentCore
import ThermoL10n
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
    /// With nothing ticked, the review button offers only what the search shows (it once offered every closable tab).
    @MainActor func testUntickedArchiveFollowsSearch() {
        let pages = [page(1), page(2), page(3, protected: "Current tab"), page(12)]
        let model = TabWorkspaceModel(app: "Fixture", preview: .init(inventory: .init(app: "Fixture", generated: Date(), pages: pages), saved: []))
        XCTAssertEqual(TabWorkspaceView.archiveDefault(model, search: "").map(\.id), [pages[0].id, pages[1].id, pages[3].id])
        XCTAssertEqual(TabWorkspaceView.archiveDefault(model, search: "Page 1").map(\.id), [pages[0].id, pages[3].id])
        XCTAssertEqual(TabWorkspaceView.archiveDefault(model, search: "Page 3").map(\.id), [], "a protected match leaves nothing to save")
        model.selected = [pages[1].id]
        XCTAssertEqual(TabWorkspaceView.archiveDefault(model, search: "Page 1").map(\.id), [pages[1].id], "ticks win over the search")
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
    /// A batch saved from a window that has since closed: the default reopen would fail, so the card asks for a window.
    @MainActor func testOriginalWindowGoneOnlyWhenEveryPendingPageLostItsWindow() {
        let open = [page(1, window: 7)]
        let model = TabWorkspaceModel(app: "Fixture", preview: .init(inventory: .init(app: "Fixture", generated: Date(), pages: open), saved: []))
        func record(_ windows: [Int], status: String = "closed") -> TabWorkspace.Archive {
            TabWorkspace.Archive(name: "B", app: "Fixture", entries: windows.enumerated().map { TabWorkspace.Entry(page: page(10 + $0.offset, window: $0.element), status: status) })
        }
        XCTAssertTrue(model.originalWindowGone(record([3])))
        XCTAssertFalse(model.originalWindowGone(record([3, 7])), "one page can still go back to its own window")
        XCTAssertFalse(model.originalWindowGone(record([3], status: "skipped")), "nothing left to reopen")
        let unloaded = TabWorkspaceModel(app: "Fixture")
        XCTAssertFalse(unloaded.originalWindowGone(record([3])), "unknown until tabs are loaded")
    }
    @MainActor func testRestoreFailurePointsAtTheWindowMenuOnlyForTheDefaultTarget() {
        let gone = "Destination window is unavailable or its browser identity changed."
        XCTAssertNotEqual(TabWorkspaceModel.restoreFailure(gone, chosenWindow: false), TabWorkspaceModel.restoreFailure(gone, chosenWindow: true))
        XCTAssertEqual(TabWorkspaceModel.restoreFailure("Group name is empty.", chosenWindow: false), tr("Group name is empty."))
    }
}
