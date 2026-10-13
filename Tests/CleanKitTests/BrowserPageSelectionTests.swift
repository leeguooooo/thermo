import XCTest
import JavaScriptCore
@testable import CleanKit

final class BrowserPageSelectionTests: XCTestCase {
    override func setUp() { L10n.override = .english }
    override func tearDown() { L10n.override = nil }
    let process = ProcessIdentity(pid: 42, uid: 501, started: Date(timeIntervalSince1970: 100), executable: "/Fixture.app/Contents/MacOS/Fixture")
    func tab(_ id: String, index: Int = 1, active: Bool? = false, url: String = "https://example.test/", title: String = "Same") -> ChromeInspector.Tab {
        .init(window: 1, index: index, url: url, title: title, browserID: id, active: active, browserProcess: process)
    }
    func testDuplicateCandidatesKeepCurrentPagesAndDoNotInventPerTabHeap() {
        let tabs = [tab("a", active: true), tab("b", index: 2), tab("c", index: 3, active: nil)]
        let report = ChromeInspector.diagnose(.init(at: Date(), rows: [
            .init(targetId: "target", type: "page", url: tabs[0].url, title: "Same", heap: 1_000_000)
        ]))
        let choices = ChromeInspector.pageChoices(tabs: tabs, report: report)
        XCTAssertEqual(choices.filter(\.recommended).map { $0.tab.browserID }, ["b"])
        XCTAssertTrue(choices.allSatisfy { $0.measured == nil }, "identical titles/URLs cannot be mapped to a measured target")
        XCTAssertTrue(choices.allSatisfy { $0.tab.canSelect }, "users may manually select a current page after reviewing the warning")
    }
    func testDuplicatesWithoutCurrentPageKeepOneCopy() {
        let choices = ChromeInspector.pageChoices(tabs: [tab("a"), tab("b", index: 2)], report: nil)
        XCTAssertEqual(choices.filter(\.recommended).map { $0.tab.browserID }, ["b"])
    }
    func testLargeHeapAloneAndUnknownCurrentStatusAreNotRecommendations() {
        let target = ChromeInspector.Target(targetId: "p", type: "page", url: "https://example.test/", title: "Same", heap: 2_000_000_000)
        let report = ChromeInspector.diagnose(.init(at: Date(), rows: [target]))
        XCTAssertFalse(ChromeInspector.pageChoices(tabs: [tab("a")], report: report)[0].recommended)
        XCTAssertFalse(ChromeInspector.pageChoices(tabs: [tab("a", active: nil), tab("b", index: 2, active: nil)], report: nil).contains(where: \.recommended))
    }
    func testOnlyFreshGrowthWithAnAdequateWindowIsARecommendation() {
        let before = Date(timeIntervalSince1970: 100)
        let first = ChromeInspector.Target(targetId: "p", type: "page", url: "https://example.test/", title: "Same", heap: 1_000_000)
        var next = first; next.heap = 30_000_000
        let report = ChromeInspector.diagnose(.init(at: before.addingTimeInterval(60), rows: [next]), before: .init(at: before, rows: [first]))
        XCTAssertTrue(ChromeInspector.pageChoices(tabs: [tab("a")], report: report)[0].recommended)
        XCTAssertFalse(ChromeInspector.pageChoices(tabs: [tab("a", active: true)], report: report)[0].recommended)
        XCTAssertFalse(ChromeInspector.pageChoices(tabs: [tab("a")], report: report, stale: true)[0].recommended)
        var short = report; short.pages[0].growth?.seconds = 10
        XCTAssertFalse(ChromeInspector.pageChoices(tabs: [tab("a")], report: short)[0].recommended)
    }
    func testMetadataUsesNativeIDsAndWindowCurrentIndex() throws {
        let tabs = try XCTUnwrap(ChromeInspector.parseTabs("[[1,2,[[\"https://example.test/\",\"Same\",\"a\"],[\"https://example.test/\",\"Same\",\"b\"]]]]", process: process))
        XCTAssertEqual(tabs.map(\.browserID), ["a", "b"])
        XCTAssertEqual(tabs.map(\.active), [false, true])
        XCTAssertNotEqual(tabs[0].selectionID, tabs[1].selectionID)
    }
    func testInvalidCurrentIndexIsUnknownRatherThanAllInactive() throws {
        let tabs = try XCTUnwrap(ChromeInspector.parseTabs("[[1,0,[[\"https://example.test/\",\"Same\",\"a\"]]]]", process: process))
        XCTAssertNil(tabs.first?.active)
        XCTAssertFalse(ChromeInspector.pageChoices(tabs: tabs, report: nil)[0].recommended)
    }
    func testOldReportsAndRestartedBrowsersCannotCloseReusedIDs() {
        let legacy = ChromeInspector.Tab(window: 1, index: 1, url: "https://example.test/", title: "Same")
        XCTAssertFalse(legacy.canSelect)
        for selected in [[legacy], [tab("a")], [tab("a"), tab("a")]] {
            var restarted = process; restarted.started = restarted.started.addingTimeInterval(1)
            let results = ChromeInspector.closeTabs(selected, app: "Fixture", identity: { _ in restarted }) { _ in
                XCTFail("an invalid or previous-session plan must not execute a closing script"); return nil
            }
            XCTAssertTrue(results.allSatisfy { $0.status == .unavailable })
        }
        var restarted = tab("a"); restarted.browserProcess?.started = process.started.addingTimeInterval(1)
        XCTAssertNotEqual(restarted.selectionID, tab("a").selectionID)
    }

    /// Execute the real closing script against synthetic browser objects; never contacts a browser.
    func close(_ plan: [ChromeInspector.Tab], fixture: String) throws -> ([ChromeInspector.TabCloseResult], JSContext) {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        let closedIDs = [];
        let activeID = 'keep';
        let entries = [];
        function page(id,url,title,fail) {
          return {id:()=>id,url:()=>url,title:()=>title,close:()=>{if(fail)throw Error('refused');closedIDs.push(id);entries=entries.filter(t=>t.id()!==id);}};
        }
        const window = {id:()=>1,tabs:()=>entries,activeTabIndex:()=>entries.findIndex(t=>t.id()===activeID)+1};
        function Application(name) {return {running:()=>true,windows:()=>[window]};}
        \(fixture)
        """.replacingOccurrences(of: "let entries =", with: "var entries ="))
        XCTAssertNil(context.exception)
        let result = ChromeInspector.closeTabs(plan, app: "Fixture", identity: { _ in self.process }) { script in
            let value = context.evaluateScript(script)
            XCTAssertNil(context.exception)
            return value?.toString()
        }
        return (result, context)
    }
    func testIdenticalTabsAndShiftingIndexesCloseOnlyTheSelectedIDs() throws {
        let (result, context) = try close([tab("b", index: 3), tab("a")], fixture: "entries=[page('a','https://example.test/','Same'),page('keep','https://example.test/','Same'),page('b','https://example.test/','Same')];")
        XCTAssertEqual(result.map(\.status), [.closed, .closed])
        XCTAssertEqual(context.evaluateScript("JSON.stringify(closedIDs)")?.toString(), "[\"b\",\"a\"]")
        XCTAssertEqual(context.evaluateScript("JSON.stringify(entries.map(t=>t.id()))")?.toString(), "[\"keep\"]")
    }
    func testUnknownCurrentMarkerCannotCloseTheActivePageWithoutAnExplicitCurrentSelection() throws {
        let (result, context) = try close([tab("current", active: nil)], fixture: "activeID='current';entries=[page('current','https://example.test/','Same')];")
        XCTAssertEqual(result.map(\.status), [.becameActive])
        XCTAssertEqual(context.evaluateScript("JSON.stringify(closedIDs)")?.toString(), "[]")
    }
    func testChangedMissingCurrentAndRefusedPagesRemainOpen() throws {
        let plan = [tab("changed"), tab("gone"), tab("current"), tab("refused"), tab("ok")]
        let (result, context) = try close(plan, fixture: "activeID='current';entries=[page('changed','https://new.test/','Same'),page('current','https://example.test/','Same'),page('refused','https://example.test/','Same',true),page('ok','https://example.test/','Same')];")
        XCTAssertEqual(result.map(\.status), [.changed, .missing, .becameActive, .failed, .closed])
        XCTAssertEqual(context.evaluateScript("JSON.stringify(closedIDs)")?.toString(), "[\"ok\"]")
    }
    func testUnavailablePostCloseInventoryDoesNotClaimVerificationOrMemorySavings() {
        let p = MachinePulse(load1: 10, load5: 10, cores: 8, thermal: .nominal, memory: .warning, swapUsedMB: 10_000, hogs: [], sampled: Date(timeIntervalSince1970: 100))
        var after = p; after.sampled = p.sampled.addingTimeInterval(5)
        let review = BrowserCloseReview(results: [.init(id: "a", status: .closed)], remaining: nil,
                                        before: .init(pulse: p, browserMemoryKB: 1000), after: .init(pulse: after, browserMemoryKB: nil))
        XCTAssertNil(review.verified)
        XCTAssertEqual(review.closed, 1)
        XCTAssertEqual(review.after.pulse.memory, .warning)
        XCTAssertTrue(review.detail.contains("no reduction is claimed"))
    }
}
