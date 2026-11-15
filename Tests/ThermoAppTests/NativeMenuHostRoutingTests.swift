import AppKit
import ModuleKit
import NativeFeatureAPI
import SwiftUI
import XCTest
@testable import ThermoApp

@MainActor final class NativeMenuHostRoutingTests:XCTestCase {
    private final class Target:NSObject {@objc func activate(_ sender:NSMenuItem){}}
    func testSearchHasOneDeclaredMenuEntryThatReturnsWhenReenabled() throws {
        _=NSApplication.shared
        let id=BuiltinModuleManifests.search.id,menu=NSMenu(),target=Target()
        let entries=BuiltinNativeFeatures.catalog.menuEntries
        XCTAssertEqual(entries.filter{$0.ref.module==id}.map(\.ref.entry),["search"])
        NativeMenuItems.append(to:menu,entries:entries,target:target,action:#selector(Target.activate(_:)),enabled:{_ in false})
        let search=try XCTUnwrap(menu.items.first{($0.representedObject as? NativeUIEntryRef)?.module==id})
        XCTAssertTrue(search.isHidden);let count=menu.items.count
        NativeMenuItems.updateVisibility(in:menu,enabled:{$0==id})
        XCTAssertFalse(search.isHidden);XCTAssertEqual(menu.items.count,count)
        XCTAssertEqual(menu.items.filter{($0.representedObject as? NativeUIEntryRef)?.module==id}.count,1)
        NativeMenuItems.updateVisibility(in:menu,enabled:{_ in false});XCTAssertTrue(search.isHidden)
    }
    func testGenericTreeRetainsFrozenTargetsAndHonorsDisabledActionsAndOwnerVisibility() throws {
        _=NSApplication.shared
        let menu=NSMenu(),owner=NativeUIEntryRef("com.example.menu","tools");var calls=0
        let nodes:[NativeMenuNode]=[.action(.init(title:"First",symbol:"doc",perform:{calls+=1})),.action(.init(title:"Disabled",enabled:false,perform:{calls+=100})),.separator,.submenu(title:"Nested",symbol:nil,items:[.action(.init(title:"Second",perform:{calls+=2}))])]
        NativeMenuRendering.append(to:menu,nodes:nodes,owner:owner)
        XCTAssertEqual(menu.items.map(\.title),["First","Disabled","","Nested"])
        XCTAssertNotNil(menu.items[0].target);XCTAssertFalse(menu.items[1].isEnabled)
        menu.performActionForItem(at:0)
        (menu.items[1].target as? NativeMenuActionTarget)?.invoke(menu.items[1])
        let nested=try XCTUnwrap(menu.items[3].submenu);nested.performActionForItem(at:0)
        XCTAssertEqual(calls,3)
        NativeMenuItems.updateVisibility(in:menu,enabled:{_ in false});XCTAssertTrue(menu.items.allSatisfy(\.isHidden))
        NativeMenuItems.updateVisibility(in:menu,enabled:{$0==owner.module});XCTAssertTrue(menu.items.allSatisfy{!$0.isHidden})
    }

    private final class MenuSession:NativeFeatureSession {
        var calls=0
        func menuContent(_ ref:NativeUIEntryRef)->NativeMenuContent?{.init(items:{_ in [.action(.init(title:"Owned action",perform:{self.calls+=1}))]},view:{_,_ in AnyView(EmptyView())})}
        func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView?{nil}
        var status:NativeFeatureStatus{.init()}
        func retireVisibility(){}
        func quitBlocker()->NativeFeatureBlocker?{nil}
        func prepareStop()throws->NativeFeatureDrain{.init{}}
    }
    func testColdAppMenuSectionAppearsAfterEnableAndRetiresOldActions() async throws {
        _=NSApplication.shared
        let id="com.example.dynamic-menu",menu=NSMenu(),target=Target(),session=MenuSession();var enabled=false,made=0
        let schema=ModuleManifest(id:id,name:"Dynamic menu",summary:"",symbol:"doc",version:"1.0.0",entries:[.init(id:"tools",kind:.menuBarItem,title:"Tools")])
        let store=NativeFeatureStore(definitions:[.init(manifest:schema,ui:.init(hasMenuContent:true),makeSession:{_ in made+=1;return session})],enabled:{_ in enabled})
        NativeMenuItems.append(to:menu,entries:store.catalog.menuEntries,target:target,action:#selector(Target.activate(_:)),enabled:{_ in enabled},content:store.menuContent)
        XCTAssertEqual(made,0);XCTAssertTrue(menu.items.allSatisfy(\.isHidden))
        enabled=true;NativeMenuItems.refreshContent(in:menu)
        let item=try XCTUnwrap(menu.items.first{$0.title=="Owned action"}),old=try XCTUnwrap(item.target as? NativeMenuActionTarget)
        XCTAssertEqual(made,1);old.invoke(item);XCTAssertEqual(session.calls,1)
        let drain=try XCTUnwrap(store.prepareStop(id));enabled=false;await drain.finish();NativeMenuItems.refreshContent(in:menu)
        XCTAssertFalse(menu.items.contains{$0.title=="Owned action"});old.invoke(item);XCTAssertEqual(session.calls,1)
        enabled=true;NativeMenuItems.refreshContent(in:menu)
        XCTAssertEqual(menu.items.filter{$0.title=="Owned action"}.count,1);XCTAssertEqual(made,2)
        old.invoke(item);XCTAssertEqual(session.calls,1)
    }

}
