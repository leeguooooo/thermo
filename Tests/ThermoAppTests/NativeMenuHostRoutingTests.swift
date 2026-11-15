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
}
