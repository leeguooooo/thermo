import XCTest
@testable import AgentDoctor
@testable import ThermoApp

final class AgentActivityTests: XCTestCase {
    @MainActor func testResultsSurviveInventoryReplacementAndRemainBounded() {
        let scanner = AgentScanner()
        for index in 0..<25 {
            scanner.recordResult(item: "fixture-\(index)", name: "Fixture", action: "Fix",
                                 result: ActionResult(ok: true, log: ["done"], backups: []))
        }
        scanner.report = nil
        XCTAssertEqual(scanner.history.count, 20)
        XCTAssertEqual(scanner.history.first?.item, "fixture-24")
        XCTAssertEqual(scanner.history.last?.item, "fixture-5")
        XCTAssertEqual(scanner.lastResult?.item, "fixture-24")
    }

    @MainActor func testBatchStaysBusyWhenItsPresentationIsCleared() async throws {
        let entered = expectation(description: "executor entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let report = DoctorReport(generated: Date(), inventory: Inventory(), findings: [], items: [], processes: [], sessions: 0)
        let item = AgentItem(id: "fixture", area: .plugins, agent: "fixture", name: "Fixture", detail: "", source: nil, enabled: true, severity: .warning)
        let action = Action(id: "fixture-action", kind: .fix, title: "Fix", summary: "", steps: [], destructive: false)
        let scanner = AgentScanner()
        scanner.performAll([(item, action)], executor: { _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return ActionResult(ok: true, log: ["completed"], backups: [])
        }, rescan: { report })
        await fulfillment(of: [entered], timeout: 2)
        scanner.batch = nil
        XCTAssertTrue(scanner.busy)
        scanner.scan()
        XCTAssertFalse(scanner.scanning)
        release.signal()
        let deadline = Date().addingTimeInterval(3)
        while scanner.batching && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(scanner.batching)
        XCTAssertEqual(scanner.history.count, 1)
        XCTAssertNotNil(scanner.report)
    }

    @MainActor func testActivityRedactsOutputsAndDeduplicatesBackupPaths() {
        let scanner = AgentScanner()
        let result = scanner.recordResult(item: "fixture", name: "Fixture", action: "Fix",
                                          result: ActionResult(ok: false, log: ["API_TOKEN=fixture-sensitive-value"],
                                                               backups: ["/fixture/backup", "/fixture/backup"]))
        XCTAssertFalse(result.result.log.joined().contains("fixture-sensitive-value"))
        XCTAssertEqual(result.result.backups, ["/fixture/backup"])
        XCTAssertFalse(result.result.ok)
    }
}
