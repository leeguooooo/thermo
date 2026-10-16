import XCTest
@testable import ThermoApp
@testable import AgentDoctor

final class SkillProjectSelectionTests: XCTestCase {
    @MainActor func testProjectChangeDropsStaleReportAndCannotChangeAnActiveScan() async throws {
        let began = expectation(description: "diagnosis started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let report = DoctorReport(generated: Date(), inventory: Inventory(), findings: [], items: [], processes: [], sessions: 0)
        let scanner = AgentScanner(diagnose: {
            began.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return report
        })
        scanner.report = report
        scanner.selection = "stale-selection"
        let project = URL(fileURLWithPath: "/fixture/project")
        scanner.selectProject(project)
        XCTAssertNil(scanner.report)
        XCTAssertNil(scanner.selection)
        await fulfillment(of: [began], timeout: 2)
        scanner.selectProject(URL(fileURLWithPath: "/fixture/other"))
        XCTAssertEqual(scanner.project, project)
        release.signal()
        for _ in 0..<200 where scanner.busy { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(scanner.busy)
        XCTAssertNotNil(scanner.report)
    }
}
