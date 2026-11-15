import XCTest
import ModuleKit
import AppKit
import NativeFeatureAPI
import SwiftUI
@testable import ThermoApp

@MainActor final class MenuBarHostRoutingTests:XCTestCase {
    func testManifestAndRegistryCoverMenuAndSettings() {
        XCTAssertEqual(MenuBarModule.manifest.launch, .always)
        XCTAssertTrue(MenuBarModule.manifest.enabledByDefault)
        XCTAssertTrue(MenuBarModule.manifest.entries.allSatisfy(MenuBarModule.supports))
        XCTAssertTrue(BuiltinModules.problems.isEmpty)
        XCTAssertEqual(Set(BuiltinModules.all.map(\.id)),Set(BuiltinModuleManifests.all.map(\.id)))
    }
    func testProductionMaterializerIncludesRecoveryWhileOrdinaryModuleIsOff() throws {
        _=NSApplication.shared
        var recovered=0
        let context=StatusMenuLayout.RuntimeContext(menuBarEnabled:false,hasBattery:false,keepAwakeActive:false,focusTimerActive:false,retainedQuickControlsAppear:true,updatesCanCheck:false,moreToolsActiveStates:.init(cleanScreenActive:false,lowLatencyActive:false,batteryProtectionActive:false))
        let content=NativeMenuContent(items:{_ in [.action(.init(title:"Restore existing icons",perform:{recovered+=1}))]},view:{_,_ in AnyView(EmptyView())})
        let menu=NSMenu(),layout=StatusMenuLayout.make(context:context)
        StatusMenu.appendRetainedControls(to:menu,layout:layout,contributions:[.init(owner:.init("com.example.recovery","tools"),content:content)])
        XCTAssertEqual(menu.items.map(\.title),["Restore existing icons"])
        menu.performActionForItem(at:0);XCTAssertEqual(recovered,1)
    }
    func testModuleOffHidesManagementEntryButKeepsEmergencyRecovery() {
        let context=StatusMenuLayout.RuntimeContext(menuBarEnabled:false,hasBattery:true,keepAwakeActive:false,focusTimerActive:false,
            retainedQuickControlsAppear:true,updatesCanCheck:true,
            moreToolsActiveStates:.init(cleanScreenActive:false,lowLatencyActive:false,batteryProtectionActive:false))
        let layout=StatusMenuLayout.make(context:context)
        XCTAssertFalse(layout.productItems.contains {if case .manageMenuBar=$0{return true};return false})
        XCTAssertFalse(layout.retainedExtras.quickControls.isEmpty)
    }
}
