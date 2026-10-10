import XCTest
@testable import AgentDoctor
@testable import thermo

final class DiagnosticCSVTests: XCTestCase {
    func testCSVKeepsGeneralFindingsAndRedactsNestedActionArguments() {
        let action = Action(id: "fixture-action", kind: .fix, title: "Fixture", summary: "", steps: [
            .run(tool: "/fixture/tool", args: ["--token", "synthetic secret value"], cwd: nil)
        ], destructive: false)
        let item = AgentItem(id: "fixture", area: .mcp, agent: "fixture", name: "Tool, with comma", detail: "", source: nil,
                             enabled: true, severity: .warning, actions: [action])
        let general = Finding(.warning, .processes, agent: "fixture", subject: "Ownership", "Could not check\nfixture")
        let csv = Export.diagnosticCSV(items: [item], findings: [general], generated: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(csv.contains("\"Tool, with comma\""))
        XCTAssertTrue(csv.contains("finding,1970-01-01T00:00:00Z,,processes,fixture,Ownership"))
        XCTAssertTrue(csv.contains("\"Could not check\nfixture\""))
        XCTAssertFalse(csv.contains("synthetic secret value"))
        XCTAssertTrue(csv.contains("••••"))
    }
}
