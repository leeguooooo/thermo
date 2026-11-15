import XCTest
@testable import ThermoApp

@MainActor final class StatusMenuLayoutTests:XCTestCase {
    private func context(battery:Bool = true,awake:Bool = false,focus:Bool = false,controls:Bool = false,updates:Bool = true,tools:StatusMenuLayout.MoreToolsActiveStates = .init(cleanScreenActive:false,lowLatencyActive:false,batteryProtectionActive:false))->StatusMenuLayout.RuntimeContext {
        .init(hasBattery:battery,keepAwakeActive:awake,focusTimerActive:focus,retainedQuickControlsAppear:controls,updatesCanCheck:updates,moreToolsActiveStates:tools)
    }
    private func leaves(_ layout:StatusMenuLayout,_ name:String)->[String] {
        layout.productItems.compactMap{if case let .menuGroup(group)=$0,group.title==name{return group.leaves.map(\.identity)};return nil}.first ?? []
    }
    private func direct(_ layout:StatusMenuLayout,_ name:String)->StatusMenuLayout.DirectStatusItem? {
        layout.productItems.compactMap{if case let .directStatusItem(item)=$0,item.title==name{return item};return nil}.first
    }
    func testDisabledCheckupHidesItsMenuEntryAndKeepsPerformance() {
        var c=context();c.checkupEnabled=false;let menu=StatusMenuLayout.make(context:c)
        XCTAssertFalse(leaves(menu,"System & hardware").contains("aiCheckup"));XCTAssertTrue(leaves(menu,"System & hardware").contains("cpuUsage"))
    }
    func testDisabledAgentDiagnosticsHidesSmartCheckAndKeepsOtherTools() {
        var c=context();c.agentsEnabled=false;let menu=StatusMenuLayout.make(context:c)
        XCTAssertFalse(leaves(menu,"More tools").contains("smartCheck"));XCTAssertTrue(leaves(menu,"More tools").contains("cleanScreen"))
    }
    func testDisabledHistoryHidesItsMenuEntryAndKeepsSettings() {
        var c=context();c.historyEnabled=false;let menu=StatusMenuLayout.make(context:c)
        XCTAssertFalse(menu.productItems.contains{if case .history=$0{return true};return false})
        XCTAssertTrue(menu.productItems.contains{if case .settings=$0{return true};return false})
    }
    func testDisabledConnectionsHidesOnlyItsQuickMenuEntry() {
        var c=context();c.connectionsEnabled=false;let menu=StatusMenuLayout.make(context:c)
        XCTAssertFalse(leaves(menu,"System & hardware").contains("connections"));XCTAssertTrue(leaves(menu,"System & hardware").contains("sensors"))
    }
    func testDisabledBrowserIsAbsentFromTheQuickMenuWithoutHidingOtherSystemTools() {
        var c=context();c.browserEnabled=false;let menu=StatusMenuLayout.make(context:c)
        XCTAssertFalse(leaves(menu,"System & hardware").contains("tabOrganizer"));XCTAssertTrue(leaves(menu,"System & hardware").contains("gpuUsage"))
    }
    func testDisabledSoftwareIsAbsentFromTheQuickMenuWithoutHidingOtherStorageTools() {
        var c=context();c.appsEnabled=false;let menu=StatusMenuLayout.make(context:c)
        XCTAssertFalse(leaves(menu,"Clean & storage").contains("software"));XCTAssertTrue(leaves(menu,"Clean & storage").contains("spaceLens"))
    }
    func testDisabledSpaceIsAbsentFromTheQuickMenuWithoutHidingSoftwareOrCleanup() {
        var c=context();c.spaceEnabled=false;let menu=StatusMenuLayout.make(context:c)
        XCTAssertFalse(leaves(menu,"Clean & storage").contains("spaceLens"));XCTAssertTrue(leaves(menu,"Clean & storage").contains("software"));XCTAssertTrue(leaves(menu,"Clean & storage").contains("smartScan"))
    }
    func testProductFirstLevelOrderMatchesSpec() {
        let menu=StatusMenuLayout.make(context:context())
        let order=menu.productItems.map{item->String in
            switch item {
            case .openThermo:return "open"
            case .searchAppsAndFiles:return "search"
            case .nativeMenus:return "nativeMenus"
            case let .menuGroup(group):return group.title
            case let .directStatusItem(item):return item.title
            case .manageMenuBar:return "menuBar"
            case .history:return "history"
            case .settings:return "settings"
            }
        }
        XCTAssertEqual(order,["open","search","nativeMenus","System & hardware","Clean & storage","More tools","Keep awake","Focus timer","menuBar","history","settings"])
    }
    func testEveryHostLeafActionAppearsExactlyOnce() {
        let menu=StatusMenuLayout.make(context:context())
        let all=menu.productItems.flatMap{item->[String] in if case let .menuGroup(group)=item{return group.leaves.map(\.identity)};return []}
        XCTAssertEqual(all.count,Set(all).count)
        XCTAssertEqual(Set(leaves(menu,"System & hardware")),Set(["overview","aiCheckup","sensors","fans","connections","cpuUsage","gpuUsage","memoryUsage","tabOrganizer"]))
        XCTAssertEqual(Set(leaves(menu,"Clean & storage")),Set(["smartScan","spaceLens","software"]))
    }
    func testBatteryAvailabilityAffectsBatteryProtection() {
        XCTAssertTrue(leaves(StatusMenuLayout.make(context:context(battery:true)),"More tools").contains("batteryProtection"))
        XCTAssertFalse(leaves(StatusMenuLayout.make(context:context(battery:false)),"More tools").contains("batteryProtection"))
    }
    func testFeatureOwnedMenusHaveOneGenericSlotAndCanDisappearWithoutHostBusinessCases() {
        var c=context();c.nativeMenusAppear=false
        XCTAssertFalse(StatusMenuLayout.make(context:c).productItems.contains{if case .nativeMenus=$0{return true};return false})
        c.nativeMenusAppear=true
        XCTAssertEqual(StatusMenuLayout.make(context:c).productItems.filter{if case .nativeMenus=$0{return true};return false}.count,1)
    }
    func testKeepAwakeActiveState() {
        XCTAssertEqual(direct(StatusMenuLayout.make(context:context(awake:true)),"Keep awake")?.isActive,true)
        XCTAssertEqual(direct(StatusMenuLayout.make(context:context(awake:false)),"Keep awake")?.isActive,false)
    }
    func testFocusTimerActiveState() {
        XCTAssertEqual(direct(StatusMenuLayout.make(context:context(focus:true)),"Focus timer")?.isActive,true)
        XCTAssertEqual(direct(StatusMenuLayout.make(context:context(focus:false)),"Focus timer")?.isActive,false)
    }
    func testMoreToolsGroupStatusHint() {
        for (battery,active,expected) in [(true,StatusMenuLayout.MoreToolsActiveStates(cleanScreenActive:true,lowLatencyActive:false,batteryProtectionActive:false),true),(true,.init(cleanScreenActive:false,lowLatencyActive:true,batteryProtectionActive:false),true),(true,.init(cleanScreenActive:false,lowLatencyActive:false,batteryProtectionActive:true),true),(false,.init(cleanScreenActive:false,lowLatencyActive:false,batteryProtectionActive:true),false),(true,.init(cleanScreenActive:false,lowLatencyActive:false,batteryProtectionActive:false),false)] {
            let menu=StatusMenuLayout.make(context:context(battery:battery,tools:active))
            let hint=menu.productItems.compactMap{if case let .menuGroup(group)=$0,group.title=="More tools"{return group.hasActiveHint};return nil}.first
            XCTAssertEqual(hint,expected)
        }
    }
    func testGroupStatusHintContainsNoPersonalData() {
        let menu=StatusMenuLayout.make(context:context(tools:.init(cleanScreenActive:true,lowLatencyActive:false,batteryProtectionActive:false)))
        let titles=menu.productItems.compactMap{if case let .menuGroup(group)=$0{return group.title};return nil}
        XCTAssertEqual(titles,["System & hardware","Clean & storage","More tools"])
    }
    func testRetainedExtrasPresence() {
        let shown=StatusMenuLayout.make(context:context(controls:true)),hidden=StatusMenuLayout.make(context:context(controls:false,updates:false))
        XCTAssertEqual(shown.retainedExtras.quickControls.count,1);XCTAssertTrue(hidden.retainedExtras.quickControls.isEmpty)
        XCTAssertTrue(shown.retainedExtras.footer.checkForUpdates.enabled);XCTAssertFalse(hidden.retainedExtras.footer.checkForUpdates.enabled)
        XCTAssertEqual(shown.retainedExtras.footer.about.title,"About Thermo");XCTAssertEqual(shown.retainedExtras.footer.quit.title,"Quit Thermo")
    }
    func testHostLeafActionIdentitiesRemainStable() {
        let menu=StatusMenuLayout.make(context:context())
        let identities=Set(menu.productItems.flatMap{item->[String] in if case let .menuGroup(group)=item{return group.leaves.map(\.identity)};return []})
        XCTAssertEqual(identities,Set(["overview","aiCheckup","sensors","fans","connections","cpuUsage","gpuUsage","memoryUsage","tabOrganizer","smartScan","spaceLens","software","claudeTools","smartCheck","cleanScreen","networkLowLatency","batteryProtection"]))
    }
}
