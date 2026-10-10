import XCTest
import ThermoL10n
@testable import AgentDoctor
@testable import ThermoApp

final class AgentCancellationTests: XCTestCase {
    @MainActor func testStopCheckingDoesNotInterruptConfirmedRepairBatch() async throws {
        let entered = expectation(description: "repair entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let report = DoctorReport(generated: Date(), inventory: Inventory(), findings: [], items: [], processes: [], sessions: 0)
        let scanner = AgentScanner()
        let item = AgentItem(id: "fixture", area: .plugins, agent: "fixture", name: "Fixture", detail: "", source: nil, enabled: true, severity: .warning)
        let action = Action(id: "fixture", kind: .fix, title: "Fixture", summary: "", steps: [], destructive: false)
        scanner.performAll([(item, action)], executor: { _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return ActionResult(ok: true, log: ["fixture completed"], backups: [])
        }, rescan: { report })
        await fulfillment(of: [entered], timeout: 2)
        scanner.stopScan()
        XCTAssertTrue(scanner.batching)
        XCTAssertFalse(scanner.stopRequested)
        release.signal()
        try await waitForIdle(scanner)
        XCTAssertEqual(scanner.history.count, 1)
        XCTAssertTrue(scanner.history[0].result.ok)
    }
    @MainActor func testStopWaitsForExitKeepsPreviousReportAndAllowsExplicitRetry() async throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let previous = DoctorReport(generated: Date(timeIntervalSince1970: 1), inventory: Inventory(), findings: [], items: [], processes: [], sessions: 0)
        let newer = DoctorReport(generated: Date(timeIntervalSince1970: 2), inventory: Inventory(), findings: [], items: [], processes: [], sessions: 0)
        let scanner = AgentScanner(diagnose: {
            _ = release.wait(timeout: .now() + 3)
            return newer
        })
        scanner.report = previous
        scanner.scan()
        scanner.stopScan()
        XCTAssertTrue(scanner.scanning)
        XCTAssertTrue(scanner.stopRequested)
        release.signal()
        try await waitForIdle(scanner)
        XCTAssertTrue(scanner.stopped)
        XCTAssertEqual(scanner.report?.generated, previous.generated)
        scanner.scan(ifOlderThan: 60)
        XCTAssertFalse(scanner.scanning)
        release.signal()
        scanner.scan()
        try await waitForIdle(scanner)
        XCTAssertFalse(scanner.stopped)
        XCTAssertEqual(scanner.report?.generated, newer.generated)
    }

    @MainActor private func waitForIdle(_ scanner: AgentScanner) async throws {
        let deadline = Date().addingTimeInterval(3)
        while scanner.busy && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(scanner.busy)
    }
}
