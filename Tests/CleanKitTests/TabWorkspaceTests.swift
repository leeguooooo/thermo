import XCTest
import JavaScriptCore
@testable import CleanKit

final class TabWorkspaceTests: XCTestCase {
    func home() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url.path
    }
    func page(_ id: String, active: Bool = false) -> TabWorkspace.Page {
        let process = ProcessIdentity(pid: 123, uid: 501, started: Date(timeIntervalSince1970: 100), executable: "/Fixture")
        return .init(tab: .init(window: 1, index: 1, url: "https://example.test/" + id, title: id, browserID: id, active: active, browserProcess: process), group: "Research", protectedReason: active ? "Current tab" : nil)
    }
    final class Fixture: @unchecked Sendable {
        var pages: [TabWorkspace.Page]
        var requests: [String] = []
        var changeBeforeClose = false
        var failVerification = false
        var reads = 0
        init(_ pages: [TabWorkspace.Page]) { self.pages = pages }
        func inventory(_ app: String) throws -> TabWorkspace.Inventory {
            reads += 1
            if failVerification && reads > 1 { throw TabWorkspace.WorkspaceError("Cannot read") }
            if changeBeforeClose { pages[0].protectedReason = "Playing audio" }
            return .init(app: app, generated: Date(), pages: pages)
        }
        func close(_ tabs: [ChromeInspector.Tab], _ app: String) -> [ChromeInspector.TabCloseResult] {
            requests += tabs.map(\.selectionID)
            pages.removeAll { tabs.map(\.selectionID).contains($0.id) }
            return tabs.map { .init(id: $0.selectionID, status: .closed) }
        }
    }
    func testSavedBeforeClosingAndRepeatedRestoreDoesNotDuplicate() async throws {
        let root = try home(); let pages = [page("one"), page("two")]; let fixture = Fixture(pages)
        let saved = try await TabWorkspace.archive(pages, app: "Fixture", name: "Research", home: root,
            readInventory: { try fixture.inventory($0) }, close: { tabs, app in
                XCTAssertEqual(try? TabWorkspace.archives(home: root).first?.entries.count, 2)
                return fixture.close(tabs, app)
            })
        XCTAssertEqual(saved.closed, 2)
        let attrs = try FileManager.default.attributesOfItem(atPath: TabWorkspace.archiveURL(saved.id, home: root).path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var opened = 0
        let first = try TabWorkspace.restore(saved.id, home: root, openPage: { page, _ in opened += 1; return "new-" + page.tab.browserID! })
        XCTAssertEqual(first.remaining, 0)
        _ = try TabWorkspace.restore(saved.id, home: root, openPage: { _, _ in XCTFail("must not open again"); return nil })
        XCTAssertEqual(opened, 2)
        XCTAssertEqual(try TabWorkspace.groups(home: root).assignments.count, 2)
    }
    func testNewProtectionSkipsWithoutClose() async throws {
        let root = try home(); let p = page("one"); let fixture = Fixture([p]); fixture.changeBeforeClose = true
        let saved = try await TabWorkspace.archive([p], app: "Fixture", name: "Test", home: root, readInventory: { try fixture.inventory($0) }, close: { fixture.close($0, $1) })
        XCTAssertEqual(saved.entries[0].status, "skipped"); XCTAssertTrue(fixture.requests.isEmpty)
    }
    func testUnknownCloseResultIsJournaledAndNotRestoredAutomatically() async throws {
        let root = try home(); let p = page("one"); let fixture = Fixture([p]); fixture.failVerification = true
        let saved = try await TabWorkspace.archive([p], app: "Fixture", name: "Test", home: root, readInventory: { try fixture.inventory($0) }, close: { fixture.close($0, $1) })
        XCTAssertEqual(saved.entries[0].status, "unconfirmed")
        _ = try TabWorkspace.restore(saved.id, home: root, openPage: { _, _ in XCTFail("unknown delivery must not be retried"); return nil })
    }
    func testUnknownRestoreIsNotRetried() async throws {
        let root = try home(); let p = page("one"); let fixture = Fixture([p])
        let saved = try await TabWorkspace.archive([p], app: "Fixture", name: "Test", home: root, readInventory: { try fixture.inventory($0) }, close: { fixture.close($0, $1) })
        let restored = try TabWorkspace.restore(saved.id, home: root, openPage: { _, _ in nil })
        XCTAssertEqual(restored.entries[0].restoreState, "unconfirmed")
        _ = try TabWorkspace.restore(saved.id, home: root, openPage: { _, _ in XCTFail("must not retry"); return nil })
    }
    func testBusyWorkspaceAndProtectedSelectionRefuseBeforeMutation() async throws {
        let root = try home(); let lock = try TabWorkspace.Lock(home: root); defer { lock.release() }
        XCTAssertThrowsError(try TabWorkspace.assign([page("one")], name: "A", home: root))
        do { _ = try await TabWorkspace.archive([page("current", active: true)], app: "Fixture", name: "Test", home: try home(), readInventory: { _ in XCTFail(); throw TabWorkspace.WorkspaceError("No") }); XCTFail() } catch {}
    }
    func testProfileConnectionsKeepStableIDsAndIgnoreNonLocalSidecars() throws {
        let root = try home()
        let dir = URL(fileURLWithPath: root + "/.chrome-use")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, url) in [("relay-cdp-url-a", "ws://127.0.0.1:1234/"), ("relay-cdp-url-b", "ws://127.0.0.1:4321/"), ("relay-cdp-url-remote", "ws://example.test:1234/"), ("relay-cdp-url", "ws://127.0.0.1:4321/")] {
            try url.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let found = TabWorkspace.connections(app: "Google Chrome", home: root, env: [:])
        XCTAssertEqual(Set(found.keys), ["a", "b"])
        XCTAssertEqual(found["a"]?.port, 1234)
        XCTAssertEqual(found["b"]?.port, 4321)
        let override = TabWorkspace.connections(app: "Google Chrome", home: root, env: ["THERMO_CDP_URL": "ws://127.0.0.1:9999/"])
        XCTAssertEqual(Set(override.keys), ["_override"])
        XCTAssertEqual(override["_override"]?.port, 9999)
    }
    func testInventoryExportsActionableExactIDs() throws {
        let p = page("one")
        let data = try JSONEncoder().encode(p)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["id"] as? String, p.id)
        XCTAssertEqual(try JSONDecoder().decode(TabWorkspace.Page.self, from: data), p)
    }
    func testNativeRestoreMatchesStringWindowIDAndNewTabIdentity() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var pages = [{id:()=> 'old',url:()=> 'https://example.test/one'}];
        var window = {id:()=> '1',activeTabIndex:()=>1,tabs:()=>pages};
        window.tabs.push = t => pages.push({id:()=> 'new',url:()=>t.url});
        function Application() {return {running:()=>true,windows:()=>[window],Tab: x=>x};}
        """)
        XCTAssertEqual(TabWorkspace.reopen(page("one"), "Fixture", execute: { context.evaluateScript($0)?.toString() }), "new")
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.evaluateScript("pages.length")?.toInt32(), 2)
    }
    func testEveryProtectionFlagAndUnknownMetadataRemainExcluded() {
        let p = page("one")
        var row: [String: Any] = ["active": false, "pinned": false, "audible": false, "incognito": false]
        XCTAssertNil(TabWorkspace.protection(p.tab, row: row, owned: [], metadata: true))
        for key in ["active", "pinned", "audible", "incognito"] {
            row[key] = true
            XCTAssertNotNil(TabWorkspace.protection(p.tab, row: row, owned: [], metadata: true))
            row[key] = false
        }
        XCTAssertNotNil(TabWorkspace.protection(p.tab, row: row, owned: ["one"], metadata: true))
        XCTAssertNotNil(TabWorkspace.protection(p.tab, row: row, owned: [], metadata: true, agentWindows: [1]))
        XCTAssertNotNil(TabWorkspace.protection(p.tab, row: nil, owned: [], metadata: false))
        row.removeValue(forKey: "pinned")
        XCTAssertNotNil(TabWorkspace.protection(p.tab, row: row, owned: [], metadata: true))
    }
    func testGroupAssignResetAndCorruptRecordsAreNotOverwritten() throws {
        let root = try home(); let p = page("one")
        try TabWorkspace.assign([p], name: "Custom", home: root)
        XCTAssertEqual(try TabWorkspace.groups(home: root).assignments[p.id], "Custom")
        try TabWorkspace.assign([p], name: nil, home: root)
        XCTAssertEqual(try TabWorkspace.groups(home: root).assignments[p.id], "example.test")
        let url = TabWorkspace.directory(home: root).appendingPathComponent("groups.json")
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try TabWorkspace.assign([p], name: "Overwrite", home: root))
        XCTAssertEqual(try String(contentsOf: url), "broken")
    }
}
