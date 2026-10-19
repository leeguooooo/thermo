import XCTest
@testable import AgentDoctor

final class ToolUsageOrderingTests: XCTestCase {
    func testInstructionOrderUsesLinkedLoadsRatherThanAcknowledgmentSize() {
        var large = row("large", estimate: 1), small = row("small", estimate: 1000)
        large.kind = "skill"; small.kind = "skill"
        var load = SkillInstructionUsage(encoding: .heuristic); load.events = 1; load.estimatedTokens = 500
        large.skillInstructions = load; load.estimatedTokens = 2; small.skillInstructions = load
        XCTAssertEqual(ToolUsageOrdering.instructions.sorted([small, large]).map(\.id), ["large", "small"])
        XCTAssertEqual(ToolUsageOrdering.text.sorted([small, large]).map(\.id), ["small", "large"])
        large.referenceEncoding = "cl100k_base"; large.skillInstructions?.referenceTokens = 1
        small.referenceEncoding = "cl100k_base"; small.skillInstructions?.referenceTokens = 10
        XCTAssertEqual(ToolUsageOrdering.instructions.sorted([large, small]).map(\.id), ["small", "large"])
    }
    func testInstructionOrderPreservesUnknownIncompleteAndInvalidCountsAfterKnownZero() throws {
        var zero = row("zero"); zero.kind = "skill"
        var load = SkillInstructionUsage(encoding: .heuristic); load.events = 1
        zero.skillInstructions = load
        XCTAssertEqual(ToolUsageOrdering.instructions.count(for: zero), 0)
        var unknown = zero; unknown.id = "unknown"; unknown.skillInstructions = nil
        XCTAssertNil(ToolUsageOrdering.instructions.count(for: unknown))
        XCTAssertEqual(ToolUsageOrdering.instructions.sorted([unknown, zero]).first?.id, "zero")
        var invalid = zero; invalid.kind = "mcp"
        XCTAssertNil(ToolUsageOrdering.instructions.count(for: invalid))
        invalid = zero; invalid.skillInstructions?.events = 0
        XCTAssertNil(ToolUsageOrdering.instructions.count(for: invalid))
        invalid = zero; invalid.skillInstructions?.incompleteEvents = 1
        XCTAssertNil(ToolUsageOrdering.instructions.count(for: invalid))
        invalid = zero; invalid.skillInstructions?.estimatedTokens = -1
        XCTAssertNil(ToolUsageOrdering.instructions.count(for: invalid))
        invalid = zero; invalid.referenceEncoding = "cl100k_base"
        XCTAssertNil(ToolUsageOrdering.instructions.count(for: invalid))
        let decoded = try JSONDecoder().decode(ToolUsageRow.self, from: JSONEncoder().encode(unknown))
        XCTAssertNil(ToolUsageOrdering.instructions.count(for: decoded))
    }
    func testErrorOrderCountsDisjointObservationsWithoutRankingByRate() {
        var many = row("many"), single = row("single"), mixed = row("mixed")
        many.calls = 100; many.completed = 100; many.reportedErrors = 2; many.invocationFailures = 0
        single.reportedErrors = 1; single.invocationFailures = 0
        mixed.calls = 4; mixed.completed = 2; mixed.unknownErrorStatus = 1
        mixed.reportedErrors = 1; mixed.invocationFailures = 2
        XCTAssertEqual(ToolUsageOrdering.errors.sorted([single, many, mixed]).map(\.id), ["mixed", "many", "single"])
        XCTAssertEqual(ToolUsageOrdering.errors.count(for: mixed), 3)
        XCTAssertEqual(single.explicitErrorRate, 1)
        XCTAssertEqual(many.explicitErrorRate, 0.02)
    }
    func testErrorOrderPreservesLegacyUnknownAndRejectsInconsistentCounts() throws {
        var zero = row("zero"); zero.invocationFailures = 0; zero.unknownErrorStatus = 1
        let legacy = row("legacy")
        XCTAssertEqual(ToolUsageOrdering.errors.count(for: zero), 0)
        XCTAssertNil(ToolUsageOrdering.errors.count(for: legacy))
        XCTAssertEqual(ToolUsageOrdering.errors.sorted([legacy, zero]).map(\.id), ["zero", "legacy"])
        var invalid = zero; invalid.reportedErrors = 1
        XCTAssertNil(ToolUsageOrdering.errors.count(for: invalid))
        invalid = zero; invalid.invocationFailures = -1
        XCTAssertNil(ToolUsageOrdering.errors.count(for: invalid))
        invalid = zero; invalid.invocationFailures = 1
        XCTAssertNil(ToolUsageOrdering.errors.count(for: invalid))
        invalid = zero; invalid.completed = 2
        XCTAssertNil(ToolUsageOrdering.errors.count(for: invalid))
        var maximum = zero; maximum.calls = Int.max; maximum.completed = Int.max
        maximum.unknownErrorStatus = 0; maximum.reportedErrors = Int.max
        XCTAssertEqual(ToolUsageOrdering.errors.count(for: maximum), Int.max)
        maximum.invocationFailures = 1
        XCTAssertNil(ToolUsageOrdering.errors.count(for: maximum))
        let decoded = try JSONDecoder().decode(ToolUsageRow.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(ToolUsageOrdering.errors.count(for: decoded))
    }
    func row(_ id: String, bytes: Int = 0, estimate: Int = 0, reference: Int? = nil) -> ToolUsageRow {
        var row = ToolUsageRow(id: id, host: "codex", kind: "mcp", name: id)
        row.completed = 1; row.calls = 1; row.returnedTextBytes = bytes
        row.returnedTextEstimatedTokens = estimate; row.referenceReturnedTextTokens = reference
        row.referenceEncoding = reference == nil ? nil : "cl100k_base"
        return row
    }
    func testTextOrderUsesSelectedTokenCountRatherThanBytes() {
        let largeBytes = row("bytes", bytes: 1000, estimate: 250, reference: 125)
        let moreTokens = row("tokens", bytes: 600, estimate: 200, reference: 200)
        XCTAssertEqual(ToolUsageOrdering.text.sorted([largeBytes,moreTokens]).map(\.id), ["tokens","bytes"])
        var a = largeBytes, b = moreTokens; a.referenceEncoding = nil; b.referenceEncoding = nil
        XCTAssertEqual(ToolUsageOrdering.text.sorted([b,a]).map(\.id), ["bytes","tokens"])
        a.referenceEncoding = "cl100k_base"; a.referenceReturnedTextTokens = nil
        XCTAssertNil(ToolUsageOrdering.text.count(for:a))
        XCTAssertEqual(ToolUsageOrdering.text.sorted([a,b]).first?.id,"tokens")
    }
    func testStructuredOrderKeepsKnownZeroBeforeUnknownAndOtherCategories() {
        var wide = row("wide", estimate: 1), zero = row("zero", estimate: 1)
        var usage = MCPStructuredContentUsage(encoding:.heuristic)
        usage.inspectedResultObjects = 1; usage.structuredResults = 1; usage.jsonBytes = 4000; usage.jsonEstimatedTokens = 1000
        wide.structuredContent = usage
        var absent = MCPStructuredContentUsage(encoding:.heuristic); absent.inspectedResultObjects = 1
        zero.structuredContent = absent
        var unknown = wide; unknown.id = "unknown"; unknown.structuredContent?.unobservableResults = 1
        var skill = wide; skill.id = "skill"; skill.kind = "skill"
        let ordered = ToolUsageOrdering.structured.sorted([unknown,skill,zero,wide])
        XCTAssertEqual(ordered.map(\.id),["wide","zero","skill","unknown"])
        XCTAssertNil(ToolUsageOrdering.structured.count(for:skill)); XCTAssertNil(ToolUsageOrdering.structured.count(for:unknown))
    }
    func testTiesAreStableAndNegativeOrUnavailableCountsNeverBecomeKnownZero() {
        let a = row("a", estimate: 0), b = row("b", estimate: 0)
        var invalid = row("invalid", estimate: -100)
        XCTAssertEqual(ToolUsageOrdering.text.sorted([b,invalid,a]).map(\.id),["a","b","invalid"])
        invalid.referenceEncoding = "cl100k_base"; invalid.referenceReturnedTextTokens = -1
        XCTAssertNil(ToolUsageOrdering.text.count(for:invalid))
        XCTAssertEqual(ToolUsageOrdering.text.sorted([invalid,a,b]).map(\.id),["a","b","invalid"])
    }
    func testOrderingIsOptionalForOlderReportsAndRoundTripsWhenDeclared() throws {
        let parser = ToolUsageParser(since:Date(timeIntervalSince1970:0),until:Date(timeIntervalSince1970:100))
        var report = parser.report()
        XCTAssertNil(try JSONDecoder().decode(ToolUsageReport.self,from:JSONEncoder().encode(report)).toolOrdering)
        report.toolOrdering = .structured
        XCTAssertEqual(try JSONDecoder().decode(ToolUsageReport.self,from:JSONEncoder().encode(report)).toolOrdering,.structured)
    }
    func testTimeOrderUsesIntervalSumRatherThanMedianOrCallCount() {
        var many = row("many"), slow = row("slow"), partial = row("partial")
        many.calls = 8; many.timingSamples = 8; many.totalObservedSeconds = 8; many.medianSeconds = 1
        slow.calls = 1; slow.timingSamples = 1; slow.totalObservedSeconds = 5; slow.medianSeconds = 5
        partial.calls = 100; partial.timingSamples = 1; partial.totalObservedSeconds = 2
        XCTAssertEqual(ToolUsageOrdering.time.sorted([partial, slow, many]).map(\.id), ["many", "slow", "partial"])
        XCTAssertEqual(ToolUsageOrdering.observedSeconds(for: partial), 2)
    }
    func testTimeOrderPreservesKnownZeroAndRejectsMissingInvalidOrUnsampledDurations() {
        var zero = row("zero"); zero.timingSamples = 1; zero.totalObservedSeconds = 0
        var unknown = row("unknown"); unknown.totalObservedSeconds = 100
        XCTAssertNil(ToolUsageOrdering.observedSeconds(for: unknown))
        XCTAssertEqual(ToolUsageOrdering.time.sorted([unknown, zero]).map(\.id), ["zero", "unknown"])
        for value in [Double.nan, Double.infinity, -1] {
            var invalid = zero; invalid.totalObservedSeconds = value
            XCTAssertNil(ToolUsageOrdering.observedSeconds(for: invalid))
        }
        unknown.timingSamples = 2
        XCTAssertNil(ToolUsageOrdering.observedSeconds(for: unknown))
        var tied = zero; tied.id = "a"
        XCTAssertEqual(ToolUsageOrdering.time.sorted([zero, tied]).map(\.id), ["a", "zero"])
    }

}
