import XCTest
@testable import CleanKit

final class TabOrganizerTests: XCTestCase {
    func page(_ id: Int, url: String = "https://example.test/read", profile: String = "first", window: Int = 1) -> TabWorkspace.Page {
        let process = ProcessIdentity(pid: 123, uid: 501, started: Date(timeIntervalSince1970: 100), executable: "/Fixture")
        return .init(tab: .init(window: window, index: id, url: url, title: "Page \(id)", browserID: String(id), active: false, browserProcess: process), group: "Local", protectedReason: nil, profileID: profile, nativeGroupID: -1, organizerVersion: 1)
    }
    func inventory(_ pages: [TabWorkspace.Page]) -> TabWorkspace.Inventory { .init(app: "Google Chrome", generated: Date(), pages: pages) }
    func home() throws -> String {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) };return url.path
    }
    func testPlannerPreservesNativeGroupsAndProtectedTabs() {
        var existing=page(3);existing.nativeGroupID=4
        var protected=page(4);protected.protectedReason="Pinned tab"
        var active=page(5);active.tab.active=true
        let plan=TabOrganizer.plan(inventory([page(1),page(2),existing,protected,active]))
        XCTAssertEqual(plan.count,2);XCTAssertEqual(plan.groups.count,1)
        XCTAssertEqual(plan.groups[0].pages.map { $0.tab.browserID },["1","2"])
    }
    func testAccountsAndWindowsAreNeverMerged() {
        let plan=TabOrganizer.plan(inventory([page(1),page(2),page(3,profile:"second"),page(4,profile:"second"),page(5,window:2),page(6,window:2)]))
        XCTAssertEqual(plan.groups.count,3);XCTAssertTrue(plan.groups.allSatisfy { $0.pages.count==2 })
    }
    func testRulesMatchDomainBoundariesAndHavePriorityAndDeterministicColors() {
        let pages=[page(1,url:"https://docs.example.test/x"),page(2,url:"https://docs.example.test/y")]
        let rules=[TabOrganizer.Rule(domain:"example.test",name:"Research",color:"purple"),.init(domain:"test",name:"Broad")]
        let p=TabOrganizer.plan(inventory(pages),rules:rules)
        XCTAssertEqual(p.groups[0].name,"Research");XCTAssertEqual(p.groups[0].color,"purple")
        XCTAssertFalse(TabOrganizer.matching("notexample.test",rules[0]))
        XCTAssertEqual(TabOrganizer.plan(inventory(pages)).groups[0].color,TabOrganizer.plan(inventory(pages)).groups[0].color)
    }
    /// An earlier batch that put tabs 1 and 2 into native group 900 named "example.test".
    func earlier(groupId: Int = 900, window: Int = 1) -> TabOrganizer.Batch {
        let group = TabOrganizer.Group(id: "first:\(window):example.test", profileID: "first", window: window, name: "example.test", color: "blue",
                                       pages: [page(1, window: window), page(2, window: window)])
        var batch = TabOrganizer.Batch(app: "Google Chrome", plan: .init(app: "Google Chrome", groups: [group], unsupported: 0, count: 2))
        batch.requests["first"] = "r1"
        batch.replies["first"] = .init(version: 1, id: "r1", phase: "complete",
                                       results: [.init(tabId: 1, groupId: groupId, status: "grouped"), .init(tabId: 2, groupId: groupId, status: "grouped")], undoResults: nil)
        return batch
    }
    func joinable(_ id: Int, window: Int = 1) -> TabWorkspace.Page { var p = page(id, window: window); p.organizerCanJoin = true; return p }

    func testANewTabJoinsTheGroupThermoMadeInsteadOfStartingAnother() {
        let live = [TabWorkspace.NativeGroup(profileID: "first", id: 900, window: 1, title: "example.test", color: "green")]
        let inv = TabWorkspace.Inventory(app: "Google Chrome", generated: Date(), pages: [joinable(7)], nativeGroups: live)
        let plan = TabOrganizer.plan(inv, batches: [earlier()], auto: true)
        XCTAssertEqual(plan.groups.count, 1, "one new tab is enough to join")
        XCTAssertEqual(plan.groups[0].groupId, 900)
        XCTAssertEqual(plan.groups[0].color, "green", "keeps the group's current color")
    }

    func testOnlyGroupsThermoMadeAreJoined() {
        // Same title, but not from a Thermo batch (e.g. a chrome-use agent group, or the user's own).
        let foreign = [TabWorkspace.NativeGroup(profileID: "first", id: 555, window: 1, title: "example.test", color: "blue")]
        let inv = TabWorkspace.Inventory(app: "Google Chrome", generated: Date(), pages: [joinable(7), joinable(8)], nativeGroups: foreign)
        let plan = TabOrganizer.plan(inv, batches: [earlier()], auto: true)
        XCTAssertNil(plan.groups.first?.groupId)
        XCTAssertEqual(plan.groups.first?.pages.count, 2)
        // Thermo's group renamed or moved to another window: not joined either.
        for live in [TabWorkspace.NativeGroup(profileID: "first", id: 900, window: 1, title: "Renamed", color: "blue"),
                     .init(profileID: "first", id: 900, window: 2, title: "example.test", color: "blue")] {
            let inv = TabWorkspace.Inventory(app: "Google Chrome", generated: Date(), pages: [joinable(7)], nativeGroups: [live])
            XCTAssertEqual(TabOrganizer.plan(inv, batches: [earlier()], auto: true).count, 0)
        }
    }

    func testAutoModeNeverAddsADuplicateWhenTheExtensionCannotJoin() {
        let live = [TabWorkspace.NativeGroup(profileID: "first", id: 900, window: 1, title: "example.test", color: "blue")]
        let inv = TabWorkspace.Inventory(app: "Google Chrome", generated: Date(), pages: [page(7), page(8)], nativeGroups: live)
        let auto = TabOrganizer.plan(inv, batches: [earlier()], auto: true)
        XCTAssertEqual(auto.count, 0); XCTAssertEqual(auto.waitingForJoin, 1)
        XCTAssertEqual(TabOrganizer.plan(inv, batches: [earlier()]).count, 2, "an explicit run still groups them")
    }

    func testJoinTargetIsSentToTheExtension() async throws {
        let live = [TabWorkspace.NativeGroup(profileID: "first", id: 900, window: 1, title: "example.test", color: "blue")]
        let plan = TabOrganizer.plan(.init(app: "Google Chrome", generated: Date(), pages: [joinable(7)], nativeGroups: live), batches: [earlier()], auto: true)
        let sent = Box()
        _ = try await TabOrganizer.organize(plan, home: try home()) { _, payload, _ in
            sent.value = (payload["groups"] as? [[String: Any]])?.first?["groupId"] as? Int
            return .init(version: 1, id: payload["id"] as! String, phase: "complete", results: [.init(tabId: 7, groupId: 900, status: "grouped")], undoResults: nil)
        }
        XCTAssertEqual(sent.value, 900)
    }
    final class Box: @unchecked Sendable { var value: Int? }

    func testAJoinThatLandsInANewGroupIsReportedNotCountedAsSuccess() async throws {
        let live = [TabWorkspace.NativeGroup(profileID: "first", id: 900, window: 1, title: "example.test", color: "blue")]
        let plan = TabOrganizer.plan(.init(app: "Google Chrome", generated: Date(), pages: [joinable(7)], nativeGroups: live), batches: [earlier()], auto: true)
        let batch = try await TabOrganizer.organize(plan, home: try home()) { _, payload, _ in
            .init(version: 1, id: payload["id"] as! String, phase: "complete", results: [.init(tabId: 7, groupId: 901, status: "grouped")], undoResults: nil)
        }
        XCTAssertTrue(batch.errors["first"]?.contains("Could not join the existing group for example.test") == true)
    }

    func testSingletonAndUnsupportedPagesStayUngroupedUnlessRuleMatches() {
        var unsupported=page(3);unsupported.organizerVersion=0
        let plain=TabOrganizer.plan(inventory([page(1),unsupported]));XCTAssertEqual(plain.count,0);XCTAssertEqual(plain.unsupported,1)
        let rule=TabOrganizer.Rule(domain:"example.test",name:"Project")
        XCTAssertEqual(TabOrganizer.plan(inventory([page(1)]),rules:[rule]).count,1)
    }
    func testPlanJSONIncludesReviewCounts() throws {
        let plan=TabOrganizer.plan(inventory([page(1),page(2)]))
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String:Any])
        XCTAssertEqual(object["count"] as? Int,2)
        XCTAssertEqual(object["unsupported"] as? Int,0)
    }
    func testConfigurationAndJournalsUsePrivateFilesWithoutConfusingSavedTabs() async throws {
        let root=try home();var config=TabOrganizer.Configuration();config.enabled=true;config.rules=[.init(domain:"example.test",name:"Research")]
        try TabOrganizer.configure(config,home:root);XCTAssertTrue(try TabOrganizer.configuration(home:root).enabled)
        let plan=TabOrganizer.plan(inventory([page(1),page(2)]),rules:config.rules)
        let batch=try await TabOrganizer.organize(plan,home:root,execute:{ _, payload, profile in
            XCTAssertEqual(profile,"first")
            XCTAssertEqual(try TabOrganizer.batches(home:root).count,1,"journal precedes mutation")
            return .init(version:1,id:payload["id"] as! String,phase:"complete",results:[.init(tabId:1,groupId:5,status:"grouped"),.init(tabId:2,groupId:5,status:"grouped")])
        })
        XCTAssertEqual(batch.grouped,2);XCTAssertTrue(try TabWorkspace.archives(home:root).isEmpty)
        let undone=try await TabOrganizer.undo(batch.id,home:root,execute:{ _,payload,_ in
            .init(version:1,id:payload["id"] as! String,phase:"undone",results:[],undoResults:[.init(tabId:1,status:"restored"),.init(tabId:2,status:"restored")])
        })
        XCTAssertEqual(undone.restored,2)
        _=try await TabOrganizer.undo(batch.id,home:root,execute:{ _,_,_ in XCTFail("do not replay undo");throw TabWorkspace.WorkspaceError("No") })
    }
}
