import AppKit
import ModuleKit
import NativeFeatureAPI
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

}
