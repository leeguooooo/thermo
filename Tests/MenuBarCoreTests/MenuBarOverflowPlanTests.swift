import XCTest
@testable import MenuBarCore

final class MenuBarOverflowPlanTests: XCTestCase {
    func testUnnotchedDisplaysStayBelowSmallestDiscardThresholdAndCoverLargest() throws {
        let plan = try XCTUnwrap(MenuBarOverflowPlan.native27(displays: [.init(width: 1920), .init(width: 2560)]))
        XCTAssertLessThan(plan.itemLength, 960)
        XCTAssertGreaterThanOrEqual(plan.totalLength, 2560)
        XCTAssertLessThan(plan.totalLength - plan.itemLength, 2560)
    }
    func testNotchConstrainsEachItemOnEveryDisplay() throws {
        let plan = try XCTUnwrap(MenuBarOverflowPlan.native27(displays: [
            .init(width: 1800, statusWidth: 790), .init(width: 1920)
        ]))
        XCTAssertLessThan(plan.itemLength, 790 * 0.75)
        XCTAssertGreaterThanOrEqual(plan.totalLength, 1920)
        XCTAssertLessThanOrEqual(plan.fillerCount, MenuBarOverflowPlan.maximumFillers)
    }
    func testDisplayCombinationBeyondFixedItemBudgetIsUnavailable() {
        XCTAssertNil(MenuBarOverflowPlan.native27(displays: [.init(width: 512), .init(width: 3840)]))
    }
    func testInvalidAndChangingDisplaySnapshotsCannotProduceUnsafeLengths() {
        XCTAssertNil(MenuBarOverflowPlan.native27(displays: []))
        for display in [MenuBarOverflowPlan.Display(width: 0), .init(width: .nan), .init(width: .infinity),
                        .init(width: 1920, statusWidth: 0), .init(width: 1920, statusWidth: 2000),
                        .init(width: 100), .init(width: .greatestFiniteMagnitude)] {
            XCTAssertNil(MenuBarOverflowPlan.native27(displays: [display]))
        }
    }
}
