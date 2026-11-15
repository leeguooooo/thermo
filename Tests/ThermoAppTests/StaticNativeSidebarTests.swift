import AppKit
import ModuleKit
import NativeFeatureAPI
import SwiftUI
import XCTest
@testable import ThermoApp

@MainActor final class StaticNativeSidebarTests:XCTestCase {
    func testMigratedSidebarRowsAppearWithoutLoadingTheirPageModels()async throws {
        _=NSApplication.shared
        let locations:[String:NativeSidebarLocation]=[
            BuiltinModuleManifests.connections.id:.machine,BuiltinModuleManifests.history.id:.footer,
            BuiltinModuleManifests.download.id:.software,BuiltinModuleManifests.checkup.id:.overview,
            BuiltinModuleManifests.plugins.id:.software,BuiltinModuleManifests.claude.id:.agents]
        let definitions=BuiltinNativeFeatures.registrations.filter{locations[$0.manifest.id] != nil}
        let store=NativeFeatureStore(definitions:definitions,enabled:{_ in true})
        defer{store.shutdown()}
        let selected=NativeFeatureRoute(BuiltinModuleManifests.claude.id,"accounts")
        let ui=store.windowUI(selection:selected,locations:Set(NativeSidebarLocation.allCases))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues:ui.sidebar.map{($0.manifest.id,$0.location)}),locations)
        let expected=Set(definitions.flatMap{definition in definition.manifest.entries.filter{$0.kind == .page}.map{NativeFeatureRoute(definition.manifest.id,$0.id)}})
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
}
