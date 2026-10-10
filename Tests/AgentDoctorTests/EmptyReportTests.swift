import XCTest
import ThermoL10n
@testable import AgentDoctor

final class EmptyReportTests: XCTestCase {
    private func report() -> DoctorReport {
        DoctorReport(generated: Date(), inventory: Inventory(), findings: [], items: [], processes: [], sessions: 0)
    }

    func testEmptyReportDoesNotClaimSuccessfulHealthCheck() {
        let previous = L10n.override
        defer { L10n.override = previous }
        L10n.override = .english
        let empty = report()
        XCTAssertFalse(empty.hasResults)
        XCTAssertEqual(empty.headline, "no agent items found")
    }

    func testHealthyInspectedItemStillReportsNoProblems() {
        let previous = L10n.override
        defer { L10n.override = previous }
        L10n.override = .english
        var inspected = report()
        inspected.items = [AgentItem(id: "fixture", area: .mcp, agent: "fixture", name: "Fixture tool",
                                    detail: "fixture", source: nil, enabled: true, severity: nil)]
        XCTAssertTrue(inspected.hasResults)
        XCTAssertEqual(inspected.headline, "no problems found")
    }

    func testStandaloneWarningIsNotDiscardedAsEmpty() {
        var incomplete = report()
        incomplete.findings = [Finding(.warning, .processes, agent: "fixture", subject: "fixture", "Could not inspect processes")]
        XCTAssertTrue(incomplete.hasResults)
        XCTAssertEqual(incomplete.count(.warning), 1)
        XCTAssertEqual(incomplete.problemCount, 1)
    }

    func testProblemsCountItemsOnceAndKeepGeneralFailures() {
        var inspected = report()
        inspected.items = [AgentItem(id: "fixture", area: .mcp, agent: "fixture", name: "Fixture tool",
                                    detail: "fixture", source: nil, enabled: true, severity: .warning)]
        var first = Finding(.warning, .mcp, agent: "fixture", subject: "fixture", "First issue")
        first.item = "fixture"
        var second = Finding(.error, .mcp, agent: "fixture", subject: "fixture", "Second issue")
        second.item = "fixture"
        inspected.findings = [first, second, Finding(.warning, .processes, agent: "fixture", subject: "fixture", "Could not inspect processes")]
        XCTAssertEqual(inspected.problemCount, 2)
        XCTAssertEqual(inspected.problemCount(in: .mcp), 1)
        XCTAssertEqual(inspected.problemCount(in: .processes), 1)
        XCTAssertEqual(inspected.general(.processes).count, 1)
    }
}
