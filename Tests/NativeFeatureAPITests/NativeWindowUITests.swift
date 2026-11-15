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
        var settingsNavigation:NativeNavigation?
        func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView?{AnyView(EmptyView())}
        func ui(_ surface:NativeUISurface,navigation:NativeNavigation)->AnyView? {
            switch surface {
            case let .sidebar(_,_,rows):surfaces.append("sidebar");for item in contributions{_ = rows(item)}
            case let .inlineSettings(ref):surfaces.append("settings:"+ref.entry);settingsNavigation=navigation
            case .renderPreview:surfaces.append("render")
            case .windowOverlay:surfaces.append("overlay")
            case .backdrop:surfaces.append("backdrop")
            case let .compactPanel(route):surfaces.append("compact:"+route.entry)
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
    func testRootLabelKeepsTheExactSelectedDestinationAndRejectsInvalidLabels()throws {
        var manifest=manifest
        manifest.entries.append(.init(id:"details",kind:.page,title:"Details"))
        let session=Session(),target=NativeFeatureRoute(id,"details")
        session.contributions=[.init(route:target,tint:.blue,displayEntry:"home"),.init(route:target,tint:.blue,displayEntry:"unknown"),.init(route:target,tint:.blue,displayEntry:"action")]
        let definition=NativeFeatureDefinition(manifest:manifest,ui:.init(sidebarLocations:[.agents]),makeSession:{_ in session})
        var opened:[NativeFeatureRoute]=[]
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true},navigation:.init{opened.append($0.route);return true})
        let group=try XCTUnwrap(store.windowUI(selection:target,locations:[.agents]).sidebar.first)
        var rows:[NativeSidebarRow]=[]
        _=group.content{rows.append($0);return AnyView(EmptyView())}
        XCTAssertEqual(rows.count,1);XCTAssertEqual(rows.first?.entry.id,"home");XCTAssertEqual(rows.first?.route,target);XCTAssertTrue(rows.first?.selected == true)
        rows.first?.open();XCTAssertEqual(opened,[target])
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
    func testSidebarTextProjectsExactlyAndRejectsMultilineOrNul()throws {
        let session=Session()
        session.contributions=[.init(route:.init(id,"home"),tint:.blue,trailing:"1.2 GB",trailingColor:.orange)]
            + ["bad\ntext","bad\rtext","bad\r\ntext","bad\0text"].map{.init(route:.init(id,"home"),tint:.blue,trailing:$0)}
        let definition=NativeFeatureDefinition(manifest:manifest,ui:.init(sidebarLocations:[.agents]),makeSession:{_ in session})
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in true})
        let group=try XCTUnwrap(store.windowUI(selection:nil,locations:[.agents]).sidebar.first)
        var rows:[NativeSidebarRow]=[]
        _=group.content{rows.append($0);return AnyView(EmptyView())}
        XCTAssertEqual(rows.count,1);XCTAssertEqual(rows.first?.trailing,"1.2 GB");XCTAssertEqual(rows.first?.trailingColor,.orange)
    }
    func testInlineSettingsChecksKindBeforeAdmissionAndRevokesOldNavigation()async throws {
        var schema=manifest
        schema.entries.append(.init(id:"settings",kind:.settingsItem,title:"Settings",scene:"settings"))
        var made=0,shown=0,enabled=false,sessions:[Session]=[]
        let definition=NativeFeatureDefinition(manifest:schema,makeSession:{_ in made+=1;let session=Session();sessions.append(session);return session})
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in enabled},navigation:.init{_ in shown+=1;return true})
        let ref=NativeUIEntryRef(id,"settings")
        XCTAssertNil(store.inlineSettings(ref));XCTAssertEqual(made,0)
        enabled=true
        for ref in [NativeUIEntryRef(id,"home"),.init(id,"action"),.init(id,"unknown"),.init("com.example.foreign","settings")] {
            XCTAssertNil(store.inlineSettings(ref))
        }
        XCTAssertEqual(made,0)
        XCTAssertNotNil(store.inlineSettings(ref));XCTAssertEqual(made,1);XCTAssertEqual(sessions[0].surfaces,["settings:settings"])
        XCTAssertNil(store.page(.init(id,"settings")));XCTAssertFalse(store.activate(ref))
        let old=try XCTUnwrap(sessions[0].settingsNavigation)
        XCTAssertTrue(old.show(.init(id,"home")));XCTAssertEqual(shown,1)
        let drain=try XCTUnwrap(store.prepareStop(id))
        XCTAssertNil(store.inlineSettings(ref));XCTAssertFalse(old.show(.init(id,"home")))
        await drain.finish();XCTAssertNotNil(store.inlineSettings(ref));XCTAssertEqual(made,2)
        XCTAssertFalse(old.show(.init(id,"home")));XCTAssertEqual(shown,1)
    }

}

@MainActor final class NativeNonPageEntryTests:XCTestCase {
    private final class Session:NativeFeatureSession {
        var starts=0,activations:[String]=[],renders=0
        func start(){starts+=1}
        func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView?{nil}
        var status:NativeFeatureStatus{.init()}
        func ui(_ surface:NativeUISurface,navigation:NativeNavigation)->AnyView?{if case .renderPreview=surface{renders+=1};return AnyView(EmptyView())}
        func activate(_ ref:NativeUIEntryRef,navigation:NativeNavigation)->Bool{activations.append(ref.entry);return true}
        func retireVisibility(){}
        func quitBlocker()->NativeFeatureBlocker?{nil}
        func prepareStop()throws->NativeFeatureDrain{.init{}}
    }
    func testCheckedNonPageAdmissionNeverStartsBackgroundWorkAndFencesDrain() async throws {
        let id="com.example.nonpage"
        let manifest=ModuleManifest(id:id,name:"Nonpage",summary:"",symbol:"doc",version:"1.0.0",entries:[.init(id:"settings",kind:.settingsItem,title:"Settings"),.init(id:"menu",kind:.menuBarItem,title:"Menu"),.init(id:"page",kind:.page,title:"Page",scene:"page")])
        var enabled=false,made=0;var sessions:[Session]=[]
        let definition=NativeFeatureDefinition(manifest:manifest,makeSession:{_ in made+=1;let s=Session();sessions.append(s);return s})
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in enabled})
        let ref=NativeUIEntryRef(id,"settings")
        XCTAssertFalse(store.canAdmitUIEntryOwner(ref));XCTAssertFalse(store.admitUIEntryOwner(ref));XCTAssertFalse(store.activate(ref));XCTAssertNil(store.renderPreview(ref));XCTAssertEqual(made,0)
        enabled=true
        XCTAssertTrue(store.canAdmitUIEntryOwner(ref));XCTAssertEqual(made,0)
        for wrong in [NativeUIEntryRef(id,"page"),.init(id,"unknown"),.init("com.example.foreign","settings")] {
            XCTAssertFalse(store.canAdmitUIEntryOwner(wrong));XCTAssertFalse(store.admitUIEntryOwner(wrong));XCTAssertFalse(store.activate(wrong));XCTAssertNil(store.renderPreview(wrong))
        }
        XCTAssertNil(store.renderPreview(.init(id,"menu")));XCTAssertEqual(made,0)
        XCTAssertTrue(store.admitUIEntryOwner(ref));XCTAssertEqual(made,1);XCTAssertEqual(sessions[0].starts,0)
        XCTAssertTrue(store.activate(ref));XCTAssertEqual(sessions[0].activations,["settings"])
        XCTAssertNotNil(store.renderPreview(ref));XCTAssertEqual(sessions[0].renders,1);XCTAssertEqual(sessions[0].starts,0)
        let drain=try XCTUnwrap(store.prepareStop(id))
        XCTAssertFalse(store.canAdmitUIEntryOwner(ref));XCTAssertFalse(store.admitUIEntryOwner(ref));XCTAssertFalse(store.activate(ref));XCTAssertNil(store.renderPreview(ref));XCTAssertEqual(made,1)
        await drain.finish();XCTAssertTrue(store.canAdmitUIEntryOwner(ref));XCTAssertEqual(made,1);XCTAssertTrue(store.admitUIEntryOwner(ref));XCTAssertEqual(made,2);XCTAssertEqual(sessions[1].starts,0)
    }

}


extension NativeWindowUITests {
    func testCompactPanelValidatesExactOwnerBeforeAdmissionAndStaysColdWhenOff() async throws {
        var made=0,enabled=false
        let session=Session()
        let definition=NativeFeatureDefinition(manifest:manifest,ui:.init(compactPanelEntry:"home"),makeSession:{_ in made+=1;return session})
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in enabled})
        XCTAssertNil(store.compactPanel(.init(id,"home")));XCTAssertEqual(made,0)
        enabled=true
        XCTAssertNil(store.compactPanel(.init(id,"action")))
        XCTAssertNil(store.compactPanel(.init(id,"home",context:["unexpected":.text("value")])))
        XCTAssertEqual(made,0)
        XCTAssertNotNil(store.compactPanel(.init(id,"home")))
        XCTAssertEqual(made,1);XCTAssertEqual(session.surfaces,["compact:home"])
        let drain=try XCTUnwrap(store.prepareStop(id))
        XCTAssertNil(store.compactPanel(.init(id,"home")));XCTAssertEqual(made,1)
        await drain.finish()
    }
    func testCompactPanelRequiresOneDeclaredContextFreePage() {
        XCTAssertThrowsError(try NativeFeatureCatalog(definitions:[.init(manifest:manifest,ui:.init(compactPanelEntry:"action"),makeSession:{_ in Session()})]))
        let required=NativePageContract(entry:"home",fields:[.init("query",kind:.text)])
        XCTAssertThrowsError(try NativeFeatureCatalog(definitions:[.init(manifest:manifest,pageContracts:[required],ui:.init(compactPanelEntry:"home"),makeSession:{_ in Session()})]))
        var other=manifest;other.id="com.example.second"
        XCTAssertThrowsError(try NativeFeatureCatalog(definitions:[manifest,other].map { schema in
            .init(manifest:schema,ui:.init(compactPanelEntry:"home"),makeSession:{_ in Session()})
        }))
    }

}
