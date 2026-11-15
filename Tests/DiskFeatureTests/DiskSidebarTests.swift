import XCTest
import ModuleKit
import NativeFeatureAPI
import CleanKit
@testable import DiskFeature

@MainActor final class DiskSidebarTests:XCTestCase {
    func rows(_ disk:DiskModel,selection:String?)->[NativeSidebarContribution] {
        BuiltinModuleManifests.disk.entries.compactMap {DiskSidebar.contribution($0,disk:disk,selection:selection.map{.init(BuiltinModuleManifests.disk.id,$0)})}
    }
    func testDynamicChildrenKeepSessionsAndOnlyShowFoundCategories() {
        let empty=DiskModel()
        XCTAssertEqual(rows(empty,selection:nil).map(\.route.entry),["scan"])
        XCTAssertEqual(rows(empty,selection:"scan").map(\.route.entry),["scan","overview","ai-sessions"])
        let item=CleanItem(id:"fixture",category:.system,title:"Fixture",safety:.safe,bytes:1024,paths:["/fixture/owned"])
        let found=DiskModel(report:.init(items:[item],denied:[],started:Date(),duration:0))
        let projected=rows(found,selection:"system")
        XCTAssertEqual(projected.map(\.route.entry),["scan","overview","ai-sessions","system"])
        XCTAssertNil(projected.first{$0.route.entry=="ai-sessions"}?.trailing)
        XCTAssertEqual(projected.first{$0.route.entry=="scan"}?.trailing,ByteFormat.string(1024))
        XCTAssertEqual(projected.last?.trailing,ByteFormat.string(1024))
    }
}
