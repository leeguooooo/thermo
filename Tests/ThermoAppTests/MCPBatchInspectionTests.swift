import XCTest
@testable import AgentDoctor
@testable import ThermoApp

final class MCPBatchInspectionTests: XCTestCase {
    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        private var now: Double = 100
        private var active = 0
        private var peak = 0
        func enter(_ id: String) { lock.lock(); ids.append(id); active += 1; peak = max(peak, active); lock.unlock() }
        func exit() { lock.lock(); active -= 1; lock.unlock() }
        func advance(_ amount: Double) { lock.lock(); now += amount; lock.unlock() }
        func time() -> Double { lock.lock(); defer { lock.unlock() }; return now }
        func snapshot() -> ([String], Int) { lock.lock(); defer { lock.unlock() }; return (ids, peak) }
    }
    static func report(_ id: String, state: MCPInspection.State = .ready) -> MCPInspection {
        var report = MCPInspection(generated: Date(), name: id, agent: "fixture", state: state)
        if state == .ready {
            report.complete = true; report.definitions = TextFootprint("[]"); report.instructions = TextFootprint("")
        }
        return report
    }
    func item(_ id: String, enabled: Bool = true, area: Area = .mcp) -> AgentItem {
        AgentItem(id: id, area: area, agent: "fixture", name: id, detail: "fixture", source: nil, enabled: enabled)
    }
    @MainActor func waitForIdle(_ model: MCPBatchInspectionModel) async throws {
        for _ in 0..<300 {
            if !model.running { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Batch inspection did not terminate")
    }
    @MainActor func testOnlyExplicitUniqueEnabledMCPItemsRunSequentially() async throws {
        let control = Control(), store = MCPDefinitionStore()
        let model = MCPBatchInspectionModel(store: store, inspector: { request in
            control.enter(request.id); defer { control.exit() }
            Thread.sleep(forTimeInterval: 0.02)
            return Self.report(request.id)
        })
        XCTAssertTrue(control.snapshot().0.isEmpty)
        XCTAssertTrue(model.start(items: [item("b"), item("a"), item("a"), item("off", enabled: false), item("skill", area: .skills)], encoding: .heuristic))
        try await waitForIdle(model)
        XCTAssertEqual(control.snapshot().0, ["a", "b"])
        XCTAssertEqual(control.snapshot().1, 1)
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertEqual(model.notStarted, 0)
        XCTAssertEqual(model.reason, .finished)
        XCTAssertEqual(store.summary(items: [item("a"), item("b")], encoding: .heuristic).completed, 2)
        store.reset()
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.reason)
        XCTAssertEqual(model.total, 0)
    }
    @MainActor func testExplicitProtocolSelectionReachesEveryBatchRequest() async throws {
        for mode in MCPInspectionProtocol.allCases {
            let store = MCPDefinitionStore()
            let model = MCPBatchInspectionModel(store: store, inspector: { request in
                XCTAssertEqual(request.protocolMode, mode)
                return Self.report(request.id)
            })
            XCTAssertTrue(model.start(items: [item("a"), item("b")], encoding: .heuristic, protocolMode: mode))
            try await waitForIdle(model)
            XCTAssertEqual(model.rows.count, 2)
        }
    }
    @MainActor func testFailureIsRetainedAndDoesNotRetryOrPreventNextConfiguration() async throws {
        let control = Control(), store = MCPDefinitionStore()
        let model = MCPBatchInspectionModel(store: store, inspector: { request in
            control.enter(request.id); defer { control.exit() }
            var report = Self.report(request.id, state: request.id == "a" ? .timedOut : .ready)
            report.message = "Fixture protocol check did not finish"
            return report
        })
        model.start(items: [item("a"), item("b")], encoding: .heuristic)
        try await waitForIdle(model)
        XCTAssertEqual(control.snapshot().0, ["a", "b"])
        XCTAssertFalse(model.rows[0].complete)
        XCTAssertEqual(model.rows[0].message, "Fixture protocol check did not finish")
        XCTAssertTrue(model.rows[1].complete)
        let summary = store.summary(items: [item("a"), item("b")], encoding: .heuristic)
        XCTAssertEqual(summary.completed, 1)
        XCTAssertEqual(summary.incomplete, 1)
    }
    @MainActor func testStopWaitsForCurrentCleanupAndLeavesQueuedConfigurationsUnknown() async throws {
        let entered = expectation(description: "first check entered"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let control = Control(), store = MCPDefinitionStore()
        store.accept(Self.report("b"), id: "b", encoding: .heuristic, ticket: store.begin("b"))
        let model = MCPBatchInspectionModel(store: store, inspector: { request in
            control.enter(request.id); defer { control.exit() }
            entered.fulfill(); _ = release.wait(timeout: .now() + 2)
            return Self.report(request.id, state: request.cancelled() ? .cancelled : .ready)
        })
        model.start(items: [item("a"), item("b")], encoding: .heuristic)
        XCTAssertNil(store.entries["b"], "A queued recheck must not retain its previous success")
        await fulfillment(of: [entered], timeout: 2)
        model.cancel()
        XCTAssertTrue(model.running)
        XCTAssertTrue(model.stopping)
        release.signal()
        try await waitForIdle(model)
        XCTAssertEqual(control.snapshot().0, ["a"])
        XCTAssertEqual(model.rows.first?.state, .cancelled)
        XCTAssertEqual(model.notStarted, 1)
        XCTAssertEqual(model.reason, .cancelled)
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertNil(store.summary(items: [item("a"), item("b")], encoding: .heuristic).definitionTokens)
    }
    @MainActor func testOverallDeadlineClampsCurrentCheckAndDoesNotStartTheRest() async throws {
        let control = Control(), store = MCPDefinitionStore()
        let model = MCPBatchInspectionModel(store: store, inspector: { request in
            control.enter(request.id); defer { control.exit() }
            XCTAssertEqual(request.timeout, 2, accuracy: 0.001)
            control.advance(3)
            XCTAssertTrue(request.cancelled())
            return Self.report(request.id, state: .cancelled)
        }, clock: { control.time() })
        model.start(items: [item("a"), item("b")], encoding: .heuristic, timeout: 10, totalBudget: 2)
        try await waitForIdle(model)
        XCTAssertEqual(control.snapshot().0, ["a"])
        XCTAssertEqual(model.reason, .budgetExpired)
        XCTAssertEqual(model.notStarted, 1)
        XCTAssertEqual(model.elapsed, 3)
    }
    @MainActor func testResetCancelsQueueAndRejectsLateMeasurements() async throws {
        let entered = expectation(description: "check entered"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = MCPDefinitionStore()
        let model = MCPBatchInspectionModel(store: store, inspector: { request in
            entered.fulfill(); _ = release.wait(timeout: .now() + 2)
            return Self.report(request.id)
        })
        model.start(items: [item("a"), item("b")], encoding: .heuristic)
        await fulfillment(of: [entered], timeout: 2)
        store.reset()
        release.signal()
        try await waitForIdle(model)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.reason)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.pending.isEmpty)
    }
    @MainActor func testInvalidOrOverlappingStartsHaveNoSideEffects() {
        let store = MCPDefinitionStore()
        let model = MCPBatchInspectionModel(store: store, inspector: { _ in XCTFail("Must not inspect"); return Self.report("unexpected") })
        XCTAssertFalse(model.start(items: [], encoding: .heuristic))
        XCTAssertFalse(model.start(items: [item("off", enabled: false)], encoding: .heuristic))
        for invalid in [Double.nan, Double.infinity, 0, -1, 121] {
            XCTAssertFalse(model.start(items: [item("a")], encoding: .heuristic, timeout: invalid))
            XCTAssertFalse(model.start(items: [item("a")], encoding: .heuristic, totalBudget: invalid))
        }
        _ = store.begin("individual")
        XCTAssertFalse(model.start(items: [item("a")], encoding: .heuristic))
        XCTAssertFalse(model.running)
    }
    @MainActor func testScannerPreventsRescanRepairAndEncodingChangesUntilBatchTerminates() async throws {
        let entered = expectation(description: "check entered"), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let scanner = AgentScanner(diagnose: { XCTFail("Must not rescan during batch"); return DoctorReport(generated: Date(), inventory: Inventory(), findings: [], items: [], processes: [], sessions: 0) }, inspectMCP: { request in
            entered.fulfill(); _ = release.wait(timeout: .now() + 2)
            return Self.report(request.id, state: .cancelled)
        })
        scanner.mcpBatch.start(items: [item("a")], encoding: .heuristic)
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(scanner.busy)
        scanner.scan(); scanner.selectEncoding(.cl100k)
        XCTAssertFalse(scanner.scanning)
        XCTAssertEqual(scanner.tokenEncoding, .heuristic)
        let action = Action(id: "fixture", kind: .fix, title: "fixture", summary: "fixture", steps: [], destructive: false)
        scanner.performAll([(item("a"), action)], executor: { _ in XCTFail("Must not repair"); return ActionResult(ok: true, log: [], backups: []) })
        XCTAssertNil(scanner.batch)
        scanner.mcpBatch.cancel(); release.signal()
        try await waitForIdle(scanner.mcpBatch)
        XCTAssertFalse(scanner.busy)
    }
}
