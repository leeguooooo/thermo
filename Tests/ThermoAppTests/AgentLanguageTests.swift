import XCTest
import ThermoL10n
@testable import AgentDoctor
@testable import ThermoApp

final class AgentLanguageTests: XCTestCase {
    func report(_ language: String) -> DoctorReport {
        var report = DoctorReport(generated: Date(), inventory: Inventory(), findings: [], items: [], processes: [], sessions: 0)
        report.language = language
        return report
    }

    @MainActor func waitForIdle(_ scanner: AgentScanner) async throws {
        let deadline = Date().addingTimeInterval(3)
        while scanner.busy && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(scanner.busy)
    }

    @MainActor func testLanguageChangeBypassesFreshReportAge() async throws {
        L10n.override = .english
        defer { L10n.override = nil }
        let translated = report("zh-Hans")
        let scanner = AgentScanner(diagnose: { translated })
        scanner.report = report("en")
        L10n.override = .simplifiedChinese
        scanner.scan(ifOlderThan: 60)
        XCTAssertTrue(scanner.scanning)
        try await waitForIdle(scanner)
        XCTAssertEqual(scanner.report?.language, "zh-Hans")
    }

    @MainActor func testLanguageChangeRefreshesAfterRepairWithoutRepeatingTheAction() async throws {
        L10n.override = .english
        defer { L10n.override = nil }
        let entered = expectation(description: "action entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let translated = report("zh-Hans")
        let previous = report("en")
        let scanner = AgentScanner(diagnose: { translated })
        scanner.report = previous
        let item = AgentItem(id: "fixture", area: .plugins, agent: "fixture", name: "Fixture", detail: "", source: nil, enabled: true, severity: .warning)
        let action = Action(id: "fixture-action", kind: .fix, title: "Fix", summary: "", steps: [], destructive: false)
        scanner.performAll([(item, action)], executor: { _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return ActionResult(ok: true, log: ["completed once"], backups: [])
        }, rescan: { previous })
        await fulfillment(of: [entered], timeout: 2)
        L10n.override = .simplifiedChinese
        scanner.scan(ifOlderThan: 60)
        XCTAssertFalse(scanner.scanning)
        release.signal()
        try await waitForIdle(scanner)
        XCTAssertEqual(scanner.report?.language, "zh-Hans")
        XCTAssertEqual(scanner.history.count, 1)
        XCTAssertEqual(scanner.batch?.results.count, 1)
    }
}
