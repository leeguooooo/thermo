import ThermoL10n
@testable import CleanKit
@testable import DiskFeature
import AgentCore
import XCTest

final class ConfirmationReviewTests: XCTestCase {
    @MainActor func testNativeToolReviewShowsEveryExecutableAndCacheBoundary() {
        let roots=["/fixture/cache-one","/fixture/cache-two"],program="/fixture/tool-bin/pip3"
        var item=CleanItem(id:"pip-cache",category:.devCaches,title:"pip cache",safety:.safe,bytes:4096,paths:roots)
        item.native=NativeClean(tool:"pip3",display:"pip cache purge",runs:roots.map {
            .init(folder:$0,argv:[program,"cache","purge","--cache-dir",$0])
        })
        let model=DiskModel(report:.init(items:[item],denied:[],started:Date(),duration:0));model.selected=[item.id]
        let lines=model.planLines.joined(separator:"\n")
        for root in roots { XCTAssertTrue(lines.contains(root),"The user must see each tool-managed cache boundary") }
        XCTAssertTrue(lines.contains(program),"The reviewed executable must be visible")
        XCTAssertTrue(model.confirmationIsDestructive)
        XCTAssertFalse(model.confirmSummary.contains(tr("Caches and build output are deleted.")))
        XCTAssertTrue(model.confirmSummary.contains(tr("Tool cache cleanup is permanent and does not use the Trash. Required files may remain.")))
        item.paths.append("/fixture/ordinary-cache-log")
        let mixed=DiskModel(report:.init(items:[item],denied:[],started:Date(),duration:0));mixed.selected=[item.id]
        XCTAssertTrue(mixed.confirmSummary.contains(tr("Caches and build output are deleted.")))
    }

    @MainActor func testPermanentToolConfirmationWarnsRegardlessOfSafetyTag() {
        for safety in [Safety.safe, .review, .risky] {
            let item = CleanItem(id: "fixture", category: .xcode, title: "fixture", safety: safety, bytes: 1,
                                 commands: [["/usr/bin/true"]], commandScope: ["/fixture/scope"])
            let model = DiskModel(report: .init(items: [item], denied: [], started: Date(), duration: 0))
            model.selected = [item.id]
            XCTAssertTrue(model.confirmationIsDestructive)
            XCTAssertFalse(model.planLines[0].contains("(0 "))
        }
    }
    @MainActor func testTrashOnlyConfirmationAndEmptySelectionAreNotPermanent() {
        for safety in [Safety.safe, .review, .risky] {
            let item = CleanItem(id: "fixture", category: .system, title: "fixture", safety: safety, bytes: 1, paths: ["/fixture/data"])
            let model = DiskModel(report: .init(items: [item], denied: [], started: Date(), duration: 0))
            XCTAssertFalse(model.confirmationIsDestructive)
            model.selected = [item.id]
            XCTAssertEqual(model.confirmationIsDestructive, safety == .safe)
        }
    }

}
