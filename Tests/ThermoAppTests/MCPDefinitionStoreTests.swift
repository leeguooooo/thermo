import XCTest
@testable import AgentDoctor
@testable import ThermoApp

final class MCPDefinitionStoreTests: XCTestCase {
    func item(_ id: String, enabled: Bool = true) -> AgentItem {
        AgentItem(id: id, area: .mcp, agent: "fixture", name: "Shared server", detail: "fixture", source: nil, enabled: enabled)
    }
    func tool(_ name: String, size: Int, issues: [String] = []) -> MCPToolFootprint {
        let empty = TextFootprint("")
        return MCPToolFootprint(name: name, description: empty, inputSchema: empty, outputSchema: empty, annotations: empty,
                                definition: TextFootprint(String(repeating: "x", count: size)), issues: issues)
    }
    func report(_ name: String = "Shared server", definitions: Int = 40, instructions: Int = 8,
                tools: [MCPToolFootprint] = []) -> MCPInspection {
        var report = MCPInspection(generated: Date(), name: name, agent: "fixture")
        report.complete = true; report.state = .ready
        report.definitions = TextFootprint(String(repeating: "x", count: definitions))
        report.instructions = TextFootprint(String(repeating: "x", count: instructions))
        report.tools = tools
        return report
    }
    @MainActor func add(_ report: MCPInspection, id: String, to store: MCPDefinitionStore, encoding: TextEncoding = .heuristic) {
        store.accept(report, id: id, encoding: encoding, ticket: store.begin(id))
    }
    @MainActor func testNoInspectionMeansUnknownRatherThanZero() {
        let store = MCPDefinitionStore()
        let summary = store.summary(items: [item("a"), item("b"), item("off", enabled: false)], encoding: .heuristic)
        XCTAssertEqual(summary.configured, 2)
        XCTAssertEqual(summary.disabled, 1)
        XCTAssertEqual(summary.completed, 0)
        XCTAssertNil(summary.definitionTokens)
        XCTAssertNil(summary.instructionTokens)
    }
    @MainActor func testIndependentConfigurationSumsDoNotMergeSameNameOrAddInstructions() {
        let store = MCPDefinitionStore()
        add(report(tools: [tool("a", size: 32), tool("b", size: 4, issues: ["fixture issue"])]), id: "a", to: store)
        add(report(definitions: 20, instructions: 4, tools: [tool("c", size: 48)]), id: "b", to: store)
        let summary = store.summary(items: [item("a"), item("a"), item("b"), item("not-inspected")], encoding: .heuristic)
        XCTAssertEqual(summary.configured, 3)
        XCTAssertEqual(summary.completed, 2)
        XCTAssertEqual(summary.definitionBytes, 60)
        XCTAssertEqual(summary.definitionTokens, 15)
        XCTAssertEqual(summary.instructionTokens, 3)
        XCTAssertEqual(summary.tools, 3)
        XCTAssertEqual(summary.toolsWithIssues, 1)
        XCTAssertEqual(summary.largest.map { $0.tool.name }, ["c", "a", "b"])
    }
    @MainActor func testStartingAgainRemovesSuccessAndIncompleteCannotReusePartialCounts() {
        let store = MCPDefinitionStore()
        add(report(tools: [tool("a", size: 32)]), id: "a", to: store)
        let ticket = store.begin("a")
        let pending = store.summary(items: [item("a")], encoding: .heuristic)
        XCTAssertEqual(pending.running, 1)
        XCTAssertEqual(pending.completed, 0)
        XCTAssertNil(pending.definitionTokens)
        var failed = report(tools: [tool("old", size: 900)])
        failed.complete = false; failed.state = .timedOut
        store.accept(failed, id: "a", encoding: .heuristic, ticket: ticket)
        let summary = store.summary(items: [item("a")], encoding: .heuristic)
        XCTAssertEqual(summary.incomplete, 1)
        XCTAssertEqual(summary.running, 0)
        XCTAssertEqual(summary.tools, 0)
        XCTAssertTrue(summary.largest.isEmpty)
        XCTAssertNil(summary.definitionTokens)
    }
    @MainActor func testResetAndNewAttemptRejectLateResults() {
        let store = MCPDefinitionStore()
        let old = store.begin("a")
        store.reset()
        let newer = store.begin("a")
        store.accept(report(), id: "a", encoding: .heuristic, ticket: old)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.pending.count, 1)
        store.accept(report(definitions: 20), id: "a", encoding: .heuristic, ticket: newer)
        XCTAssertEqual(store.summary(items: [item("a")], encoding: .heuristic).definitionTokens, 5)
        let oldRecheck = store.begin("a")
        let latestRecheck = store.begin("a")
        store.accept(report(definitions: 900), id: "a", encoding: .heuristic, ticket: oldRecheck)
        XCTAssertTrue(store.entries.isEmpty)
        store.accept(report(definitions: 8), id: "a", encoding: .heuristic, ticket: latestRecheck)
        XCTAssertEqual(store.summary(items: [item("a")], encoding: .heuristic).definitionTokens, 2)
    }
    @MainActor func testCompleteEmptyListHasMeasuredCountsRatherThanUnknown() {
        let store = MCPDefinitionStore()
        var empty = report(tools: [])
        empty.definitions = TextFootprint("[]")
        empty.instructions = TextFootprint("")
        add(empty, id: "a", to: store)
        let summary = store.summary(items: [item("a")], encoding: .heuristic)
        XCTAssertEqual(summary.completed, 1)
        XCTAssertEqual(summary.tools, 0)
        XCTAssertEqual(summary.definitionTokens, 1)
        XCTAssertEqual(summary.instructionTokens, 0)
    }
    @MainActor func testEncodingMismatchDoesNotFallBackToHeuristicOrMixReports() {
        let store = MCPDefinitionStore()
        add(report(tools: [tool("a", size: 8)]), id: "a", to: store, encoding: .cl100k)
        let reference = store.summary(items: [item("a")], encoding: .cl100k)
        XCTAssertEqual(reference.completed, 1)
        XCTAssertNil(reference.definitionTokens)
        XCTAssertEqual(reference.uncountedTools, 1)
        XCTAssertTrue(reference.largest.isEmpty)
        XCTAssertEqual(store.summary(items: [item("a")], encoding: .heuristic).completed, 0)
    }
    @MainActor func testMissingReferenceArrayCountKeepsSumUnknownButKnownToolRankingUsable() {
        let store = MCPDefinitionStore()
        var sample = report(tools: [tool("a", size: 8)])
        sample.definitions?.referenceEncoding = "cl100k_base"
        sample.definitions?.referenceTokens = nil
        add(sample, id: "a", to: store)
        let result = store.summary(items: [item("a")], encoding: .heuristic)
        XCTAssertNil(result.definitionTokens)
        XCTAssertEqual(result.largest.count, 1)
    }
    @MainActor func testRankingRemainsCorrectWithBoundedRowsAndCurrentScopeOnly() {
        let store = MCPDefinitionStore()
        add(report(tools: (1...30).map { tool("a\($0)", size: $0 * 4) }), id: "a", to: store)
        add(report(tools: [tool("biggest", size: 200)]), id: "b", to: store)
        XCTAssertEqual(store.entries["a"]?.largest.count, 10)
        let result = store.summary(items: [item("a"), item("b")], encoding: .heuristic)
        XCTAssertEqual(result.tools, 31)
        XCTAssertEqual(result.largest.count, 10)
        XCTAssertEqual(result.largest.first?.tool.name, "biggest")
        XCTAssertEqual(store.summary(items: [item("a"), item("b", enabled: false)], encoding: .heuristic).tools, 30)
        XCTAssertEqual(store.summary(items: [item("removed")], encoding: .heuristic).completed, 0)
    }
    @MainActor func testConfigurationRescanInvalidatesMeasurementsImmediately() async throws {
        let fixture = DoctorReport(generated: Date(), inventory: Inventory(), findings: [], items: [item("a")], processes: [], sessions: 0)
        let scanner = AgentScanner(diagnose: { fixture })
        add(report(), id: "a", to: scanner.mcpDefinitions)
        scanner.scan()
        XCTAssertTrue(scanner.mcpDefinitions.entries.isEmpty)
        for _ in 0..<200 {
            if !scanner.busy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(scanner.busy)
    }
}
