import XCTest
@testable import ThermoApp
@testable import AgentDoctor

final class DiagnosticActionPriorityTests: XCTestCase {
    func item(_ area: Area, actions: [Action]) -> AgentItem {
        var item = AgentItem(id: "fixture", area: area, agent: "fixture", name: "fixture", detail: "fixture", source: nil, enabled: true)
        item.actions = actions
        return item
    }
    func action(_ kind: ActionKind) -> Action {
        Action(id: kind.rawValue, kind: kind, title: "fixture", summary: "fixture", steps: [], destructive: kind == .uninstall, bulk: false)
    }
    func testSkillReviewDoesNotPromoteRemovalAsThePrimaryRemedy() {
        XCTAssertNil(item(.skills, actions: [action(.uninstall)]).primaryDiagnosticAction)
    }
    func testExplicitSkillRepairRemainsAvailableBeforeRemoval() {
        XCTAssertEqual(item(.skills, actions: [action(.uninstall), action(.fix)]).primaryDiagnosticAction?.kind, .fix)
    }
    func testExistingNonSkillActionPriorityIsPreserved() {
        XCTAssertEqual(item(.mcp, actions: [action(.uninstall)]).primaryDiagnosticAction?.kind, .uninstall)
        XCTAssertEqual(item(.mcp, actions: [action(.uninstall), action(.fix)]).primaryDiagnosticAction?.kind, .fix)
    }
}
