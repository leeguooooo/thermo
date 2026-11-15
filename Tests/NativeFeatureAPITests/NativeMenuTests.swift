import ModuleKit
import SwiftUI
import XCTest
@testable import NativeFeatureAPI

@MainActor final class NativeMenuTests:XCTestCase {
    private let id="com.example.menu"
    private var manifest:ModuleManifest{.init(id:id,name:"Menu fixture",summary:"",symbol:"doc",version:"1.0.0",entries:[.init(id:"tools",kind:.menuBarItem,title:"Tools"),.init(id:"settings",kind:.settingsItem,title:"Settings")])}
    private final class Session:NativeFeatureSession {
        var nodes:[NativeMenuNode]=[]
        func menuContent(_ ref:NativeUIEntryRef)->NativeMenuContent?{.init(items:{_ in self.nodes},view:{_,renderer in renderer(self.nodes)})}
        func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView?{nil}
        var status:NativeFeatureStatus{.init()}
        func retireVisibility(){}
        func quitBlocker()->NativeFeatureBlocker?{nil}
        func prepareStop()throws->NativeFeatureDrain{.init{}}
    }
    private func actions(_ nodes:[NativeMenuNode])->[NativeMenuAction] {
        nodes.flatMap{node in switch node{case let .action(a):return [a];case let .submenu(_,_,items):return actions(items);case .separator:return []}}
    }
    func testWrongKindOffAndUnadvertisedMenusNeverAdmitASession() {
        var made=0,enabled=false;let session=Session()
        let definition=NativeFeatureDefinition(manifest:manifest,ui:.init(hasMenuContent:true),makeSession:{_ in made+=1;return session})
        let store=NativeFeatureStore(definitions:[definition],enabled:{_ in enabled})
        XCTAssertNil(store.menuContent(.init(id,"tools")));XCTAssertEqual(made,0)
        enabled=true
        for ref in [NativeUIEntryRef(id,"settings"),.init(id,"unknown"),.init("com.example.foreign","tools")]{XCTAssertNil(store.menuContent(ref))}
        XCTAssertEqual(made,0)
        let leaf=NativeFeatureDefinition(manifest:manifest,makeSession:{_ in made+=1;return session})
        let other=NativeFeatureStore(definitions:[leaf],enabled:{_ in true})
        XCTAssertNil(other.menuContent(.init(id,"tools")));XCTAssertEqual(made,0)
        XCTAssertTrue(store.catalog.menuEntries[0].hasContent);XCTAssertFalse(other.catalog.menuEntries[0].hasContent)
    }
    func testSnapshotsAndObservingViewsShareGenerationFences() async throws {
        var calls=0
        let session=Session();session.nodes=[.submenu(title:"Nested",symbol:nil,items:[.action(.init(title:"Run",perform:{calls+=1})),.action(.init(title:"Disabled",enabled:false,perform:{calls+=100}))])]
        let store=NativeFeatureStore(definitions:[.init(manifest:manifest,ui:.init(hasMenuContent:true),makeSession:{_ in session})],enabled:{_ in true})
        let ref=NativeUIEntryRef(id,"tools"),old=try XCTUnwrap(store.menuContent(ref))
        let snapshot=actions(old.items(.status));snapshot.forEach{$0.perform()};XCTAssertEqual(calls,1)
        var mounted:[NativeMenuAction]=[]
        _=old.view(.popover,renderer:.init{mounted=self.actions($0);return AnyView(EmptyView())})
        mounted.forEach{$0.perform()};XCTAssertEqual(calls,2)
        let drain=try XCTUnwrap(store.prepareStop(id))
        snapshot.forEach{$0.perform()};mounted.forEach{$0.perform()};XCTAssertEqual(calls,2)
        XCTAssertTrue(old.items(.status).isEmpty);XCTAssertNil(store.menuContent(ref))
        await drain.finish()
        let fresh=try XCTUnwrap(store.menuContent(ref));actions(fresh.items(.status)).forEach{$0.perform()};XCTAssertEqual(calls,3)
        snapshot.forEach{$0.perform()};XCTAssertEqual(calls,3)
    }
    func testOversizedTreeIsRejectedWithoutPartialActions() throws {
        let session=Session();session.nodes=Array(repeating:.separator,count:513)
        let store=NativeFeatureStore(definitions:[.init(manifest:manifest,ui:.init(hasMenuContent:true),makeSession:{_ in session})],enabled:{_ in true})
        let content=try XCTUnwrap(store.menuContent(.init(id,"tools")))
        XCTAssertTrue(content.items(.status).isEmpty)
        var rendered=false
        _=content.view(.popover,renderer:.init{_ in rendered=true;return AnyView(EmptyView())})
        XCTAssertFalse(rendered)
    }
}
