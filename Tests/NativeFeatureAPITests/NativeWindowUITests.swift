import SwiftUI
import ModuleKit
import XCTest
@testable import NativeFeatureAPI

@MainActor final class NativeWindowUITests:XCTestCase {
    private let id="com.example.window"
    private var manifest:ModuleManifest{.init(id:id,name:"Window fixture",summary:"",symbol:"doc",version:"1.0.0",entries:[.init(id:"home",kind:.page,title:"Home",scene:"fixture"),.init(id:"action",kind:.menuBarItem,title:"Action")])}
    private final class Session:NativeFeatureSession {
        var contributions:[NativeSidebarContribution]=[]
        var surfaces:[String]=[]
        func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView?{AnyView(EmptyView())}
        func ui(_ surface:NativeUISurface,navigation:NativeNavigation)->AnyView? {
            switch surface {
            case let .sidebar(_,_,rows):surfaces.append("sidebar");for item in contributions{_ = rows(item)}
            case .windowOverlay:surfaces.append("overlay")
            case .backdrop:surfaces.append("backdrop")
            }
            return AnyView(EmptyView())
        }
        var status:NativeFeatureStatus{.init(modelLoaded:true)}
        func retireVisibility(){}
        func quitBlocker()->NativeFeatureBlocker?{nil}
        func prepareStop()throws->NativeFeatureDrain{.init{}}
    }
    func testDeclarationsStatusAndOffSurfacesRemainCold()throws {
        var made=0
        let definition=NativeFeatureDefinition(manifest:manifest,ui:.init(sidebarLocations:[.agents],hasOverlay:true,hasBackdrop:true),makeSession:{_ in made+=1;return Session()})
        let catalog=try NativeFeatureCatalog(definitions:[definition])
        let store=NativeFeatureStore(catalog:catalog,enabled:{_ in false},navigation:.unavailable)
        XCTAssertEqual(catalog.manifest(id)?.name,"Window fixture")
        XCTAssertNil(store.quitBlocker());XCTAssertFalse(store.status(id).modelLoaded)
        let ui=store.windowUI(selection:.init(id,"home"),locations:[.agents])
        XCTAssertTrue(ui.sidebar.isEmpty);XCTAssertNil(ui.backdrop);XCTAssertEqual(made,0)
    }
    func testUnattachedSidebarDoesNotAdmitAndOverlayCanAttachFirst() {
        var made=0
        let plain=NativeFeatureDefinition(manifest:manifest,ui:.init(sidebarLocations:[.agents]),makeSession:{_ in made+=1;return Session()})
        let store=NativeFeatureStore(definitions:[plain],enabled:{_ in true})
        XCTAssertTrue(store.windowUI(selection:nil,locations:[.storage]).sidebar.isEmpty);XCTAssertEqual(made,0)
        let session=Session()
        let overlay=NativeFeatureDefinition(manifest:manifest,ui:.init(hasOverlay:true),makeSession:{_ in made+=1;return session})
        let other=NativeFeatureStore(definitions:[overlay],enabled:{_ in true})
        _=other.windowUI(selection:nil,locations:[])
        XCTAssertEqual(made,1);XCTAssertEqual(session.surfaces,["overlay"])
    }
    func testCheckedRowsUseCatalogMetadataAndOnlyDeclaredOwnPages()throws {
        let session=Session()
        session.contributions=[.init(route:.init(id,"home"),tint:.blue,badge:3),.init(route:.init(id,"action"),tint:.blue),.init(route:.init(id,"unknown"),tint:.blue),.init(route:.init("com.example.foreign","home"),tint:.blue),.init(route:.init(id,"home"),tint:.blue,badge:-1)]
        let definition=NativeFeatureDefinition(manifest:manifest,ui:.init(sidebarLocations:[.agents],hasOverlay:true,hasBackdrop:true),makeSession:{_ in session})
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true})
        let ui=store.windowUI(selection:.init(id,"home"),locations:[.agents])
        XCTAssertEqual(session.surfaces,["overlay","backdrop"],"row construction belongs to actual sidebar namespace")
        var rows:[NativeSidebarRow]=[]
        _=try XCTUnwrap(ui.sidebar.first).content{rows.append($0);return AnyView(EmptyView())}
        XCTAssertEqual(rows.count,1);XCTAssertEqual(rows[0].entry,manifest.entries[0]);XCTAssertEqual(rows[0].manifest,manifest)
        XCTAssertEqual(rows[0].badge,3);XCTAssertTrue(rows[0].selected)
    }
    func testOldRowsAndDeferredRendererStayRevokedAcrossReenable()async throws {
        var made=0,shows=0,sessions:[Session]=[]
        let id=id
        let definition=NativeFeatureDefinition(manifest:manifest,ui:.init(sidebarLocations:[.agents],hasOverlay:true,hasBackdrop:true),makeSession:{_ in
            made+=1;let session=Session();session.contributions=[.init(route:.init(id,"home"),tint:.purple)];sessions.append(session);return session
        })
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true},navigation:.init{_ in shows+=1;return true})
        let ui=store.windowUI(selection:.init(id,"home"),locations:[.agents]),group=try XCTUnwrap(ui.sidebar.first)
        var row:NativeSidebarRow?
        _=group.content{row=$0;return AnyView(EmptyView())}
        try XCTUnwrap(row).open();XCTAssertEqual(shows,1)
        let first=sessionSidebarCalls(sessions[0]),drain=try XCTUnwrap(store.prepareStop(id))
        try XCTUnwrap(row).open();_=group.content{_ in XCTFail("retired renderer");return AnyView(EmptyView())}
        XCTAssertEqual(shows,1);XCTAssertEqual(sessionSidebarCalls(sessions[0]),first)
        XCTAssertTrue(store.windowUI(selection:.init(id,"home"),locations:[.agents]).sidebar.isEmpty)
        await drain.finish();_=store.windowUI(selection:.init(id,"home"),locations:[.agents])
        XCTAssertEqual(made,2);try XCTUnwrap(row).open();XCTAssertEqual(shows,1)
    }
    private func sessionSidebarCalls(_ session:Session)->Int{session.surfaces.filter{$0=="sidebar"}.count}
    func testSidebarAndBackdropRequireRealPages() {
        let empty=ModuleManifest(id:id,name:"Empty",summary:"",symbol:"doc",version:"1.0.0",entries:[])
        XCTAssertThrowsError(try NativeFeatureCatalog(definitions:[.init(manifest:empty,ui:.init(sidebarLocations:[.agents]),makeSession:{_ in Session()})]))
        XCTAssertThrowsError(try NativeFeatureCatalog(definitions:[.init(manifest:empty,ui:.init(hasBackdrop:true),makeSession:{_ in Session()})]))
    }
}
