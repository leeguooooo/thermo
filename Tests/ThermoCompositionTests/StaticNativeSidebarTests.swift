import AppKit
import ModuleKit
import NativeFeatureAPI
import SwiftUI
import XCTest
@testable import ThermoShell
@testable import ThermoComposition

@MainActor final class StaticNativeSidebarTests:ThermoCompositionTestCase {
    func testMigratedSidebarRowsAppearWithoutLoadingTheirPageModels()async throws {
        _=NSApplication.shared
        let locations:[String:NativeSidebarLocation]=[
            BuiltinModuleManifests.connections.id:.machine,BuiltinModuleManifests.history.id:.footer,
            BuiltinModuleManifests.download.id:.software,BuiltinModuleManifests.checkup.id:.overview,
            BuiltinModuleManifests.plugins.id:.software,BuiltinModuleManifests.claude.id:.agents,
            BuiltinModuleManifests.apps.id:.software,BuiltinModuleManifests.space.id:.storage,BuiltinModuleManifests.browser.id:.resources]
        let definitions=ShellNativeCatalog.registrations.filter{locations[$0.manifest.id] != nil}
        let store=NativeFeatureStore(definitions:definitions,enabled:{_ in true})
        defer{store.shutdown()}
        let selected=NativeFeatureRoute(BuiltinModuleManifests.claude.id,"accounts")
        let ui=store.windowUI(selection:selected,locations:Set(NativeSidebarLocation.allCases))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues:ui.sidebar.map{($0.manifest.id,$0.location)}),locations)
        let expected=Set(try definitions.flatMap{definition in
            let pages=definition.manifest.entries.filter{$0.kind == .page}
            let shown=definition.manifest.id==BuiltinModuleManifests.claude.id ? pages:Array(pages.prefix(1))
            return try shown.map{try store.catalog.normalize(.init(definition.manifest.id,$0.id))}
        })
        let appeared=expectation(description:"all contributed rows rendered");appeared.expectedFulfillmentCount=expected.count
        var seen=Set<NativeFeatureRoute>()
        let content=VStack{ForEach(ui.sidebar){group in group.content{row in
            if expected.contains(row.route),seen.insert(row.route).inserted{appeared.fulfill()}
            return AnyView(Text(row.entry.title))
        }}}
        let window=NSWindow(contentRect:.init(x:-6000,y:-6000,width:250,height:500),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        defer{window.contentViewController=nil;window.orderOut(nil)}
        window.contentViewController=NSHostingController(rootView:content);window.orderBack(nil)
        await fulfillment(of:[appeared],timeout:2)
        XCTAssertEqual(seen,expected)
        for id in locations.keys {XCTAssertFalse(store.status(id).modelLoaded,id)}
    }
    func testEveryBundledNativePageOwnerDeclaresItsSidebarContribution() {
        for definition in ShellNativeCatalog.registrations where definition.manifest.entries.contains(where:{$0.kind == .page}) {
            XCTAssertFalse(definition.ui.sidebarLocations.isEmpty,definition.manifest.id)
        }
    }
}
