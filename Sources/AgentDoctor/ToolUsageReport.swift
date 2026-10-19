import Foundation
import ThermoL10n

/// Returned-text accounting within one observed category, never request/billing usage.
public struct ToolUsageTextSummary: Sendable {
    public let kind: String
    public let returnedTextBytes: Int?
    public let returnedTextTokens: Int?
    public let referenceEncoding: String?
    private let rowIDs: Set<String>

    init(rows: [ToolUsageRow], kind: String, encoding: String?) {
        self.kind = kind
        referenceEncoding = encoding
        rowIDs = Set(rows.map(\.id))
        returnedTextBytes = Self.sum(rows.map { Optional($0.returnedTextBytes) })
        returnedTextTokens = Self.sum(rows.map { Self.tokens($0, encoding: encoding) })
    }

    private static func sum(_ counts: [Int?]) -> Int? {
        var total = 0
        for count in counts {
            guard let count, count >= 0 else { return nil }
            let next = total.addingReportingOverflow(count)
            guard !next.overflow else { return nil }
            total = next.partialValue
        }
        return total
    }

    private static func tokens(_ row: ToolUsageRow, encoding: String?) -> Int? {
        guard row.referenceEncoding == encoding else { return nil }
        guard encoding != nil else { return row.returnedTextEstimatedTokens }
        guard (row.unavailableReferenceResults ?? 0) == 0 else { return nil }
        if row.completed == 0 && row.returnedTextBytes == 0 { return 0 }
        return row.referenceReturnedTextTokens
    }

    public func percentage(of row: ToolUsageRow) -> Double? {
        guard row.kind == kind, rowIDs.contains(row.id),
              let total = returnedTextTokens, total > 0,
              let count = Self.tokens(row, encoding: referenceEncoding), count >= 0, count <= total else { return nil }
        return Double(count) / Double(total) * 100
    }
}

public struct ToolUsageRow: Codable, Identifiable, Sendable {
    public var id: String
    public var host: String
    public var kind: String
    public var server: String?
    public var name: String
    public var referenceEncoding: String? = nil
    public var referenceReturnedTextTokens: Int? = nil
    public var unavailableReferenceResults: Int? = nil
    public var calls = 0
    public var completed = 0
    public var reportedErrors = 0
    /// Explicit MCP result labels only; absent in older reports means unmeasured.
    public var reportedErrorCodes: [String: Int]? = nil
    public var errorCodeCategoriesLimited: Bool? = nil
    /// Host failure with no MCP result. Absent in older reports means unmeasured.
    public var invocationFailures: Int? = nil
    public var unknownErrorStatus = 0
    public var missingResults = 0
    public var timingSamples = 0
    public var totalObservedSeconds: Double? = nil
    public var medianSeconds: Double?
    /// Nearest-rank P95, only when at least 20 valid call/completion pairs exist.
    public var p95Seconds: Double?
    public var returnedTextBytes = 0
    public var returnedTextEstimatedTokens = 0
    /// Observations of the text representation, not proof of model delivery or media cost.
    /// Absent in older reports means unchecked. Counts completed results, not blocks.
    public var serializedMediaTextResults: Int? = nil
    public var truncationMarkerResults: Int? = nil
    public var nonTextBlocks = 0
    /// Outer results with unsupported content. Absent for older reports and other categories.
    public var unmeasuredResults: Int? = nil
    /// Absent in older reports means unmeasured. Zero events never proves zero loading.
    public var skillInstructions: SkillInstructionUsage? = nil
    public var observedInstructionTokens: Int? {
        guard let loaded = skillInstructions, loaded.events > 0, loaded.incompleteEvents == 0 else { return nil }
        return referenceEncoding == nil ? loaded.estimatedTokens : loaded.referenceTokens
    }

    /// Only completed results with a Boolean error status are a usable denominator.
    /// These are observations, not a task success rate or an estimate for missing results.
    public var knownStatusResults: Int? {
        guard completed >= 0, unknownErrorStatus >= 0, unknownErrorStatus <= completed,
              reportedErrors >= 0, reportedErrors <= completed - unknownErrorStatus else { return nil }
        return completed - unknownErrorStatus
    }
    public var explicitErrorRate: Double? {
        guard let denominator = knownStatusResults, denominator > 0 else { return nil }
        return Double(reportedErrors) / Double(denominator)
    }
}

public struct LoggedTokenUsage: Codable, Sendable {
    public var host: String
    public var requests = 0
    public var inputTokens = 0
    public var cachedInputTokens: Int? = 0
    public var cacheWriteInputTokens: Int? = 0
    public var outputTokens = 0
    public var semantics: String
}

/// Other tool results, kept separate from MCP/Skill rows and their denominators.
public struct UnattributedToolResults: Codable, Sendable {
    public var completed = 0
    public var missingResults = 0
    public var unmeasuredResults = 0
    public var returnedTextBytes = 0
    public var returnedTextEstimatedTokens = 0
    public var referenceReturnedTextTokens: Int? = nil
    public var unavailableReferenceResults = 0
    public var nonTextBlocks = 0
    /// Same outer observations as this aggregate, grouped only by logged tool name.
    /// Never add these rows to the aggregate or to separately logged nested MCP results.
    public var byTool: [ToolUsageRow]? = nil
}

public struct ToolUsageCoverage: Codable, Sendable {
    public var filesDiscovered = 0
    public var filesRead = 0
    public var clippedFiles = 0
    public var unreadableFiles = 0
    public var malformedLines = 0
    public var oversizedLines = 0
    public var bytesRead = 0
    public var duplicateRecords = 0
    public var otherToolCalls = 0
    /// Absent in older reports means unmeasured, never zero.
    public var unattributedResults: UnattributedToolResults? = nil
    public var unmatchedResults = 0
    public var missingTimestamps = 0
    public var unsupportedUsageRecords = 0
    public var unmatchedInstructionEvents: Int? = nil
    public var limitReached = false
    public var cancelled = false
}

public struct ToolUsageReport: Codable, Sendable {
    public var generated: Date
    public var since: Date
    public var until: Date
    /// Selected log reading only; never a guarantee of complete attribution or account usage.
    public var complete: Bool
    public var coverage: ToolUsageCoverage
    public var tools: [ToolUsageRow]
    /// Request-level counters, deliberately never allocated to individual tools.
    public var sessionTokens: [LoggedTokenUsage]
    /// Absent in older reports means unmeasured. Never sum these session snapshots.
    public var cumulativeTokenSnapshots: [CumulativeTokenSnapshot]? = nil
    public var note: String
    public var referenceEncoding: String? = nil
    public var referenceEngine: String? = nil
    public var returnedTextEstimator: String? = "ascii4-unicode1-v1"
    /// Selected-file scope only. No input path is retained or exported.
    public var singleLogFile: Bool? = nil
    /// Absent in older reports means unchecked; row sums cannot reconstruct interval overlap.
    public var timingSummaries: [ToolUsageTimingSummary]? = nil

    public func returnedTextSummary(kind: String) -> ToolUsageTextSummary {
        ToolUsageTextSummary(rows: tools.filter { $0.kind == kind }, kind: kind, encoding: referenceEncoding)
    }

    public var outerReturnedTextSummary: ToolUsageTextSummary? {
        guard let rows = coverage.unattributedResults?.byTool else { return nil }
        return ToolUsageTextSummary(rows: rows, kind: "outer", encoding: referenceEncoding)
    }

    public var observedSkillInstructions: SkillInstructionUsage? {
        let skills = tools.filter { $0.kind == "skill" }
        guard !skills.isEmpty, skills.allSatisfy({ $0.skillInstructions != nil && $0.referenceEncoding == referenceEncoding }) else { return nil }
        var total = SkillInstructionUsage(referenceEncoding: referenceEncoding)
        for skill in skills { total.merge(skill.skillInstructions!) }
        return total
    }

    public func observedInstructionPercentage(of row: ToolUsageRow) -> Double? {
        guard row.kind == "skill", tools.contains(where: { $0.id == row.id }), row.referenceEncoding == referenceEncoding,
              let summary = observedSkillInstructions, summary.incompleteEvents == 0,
              let count = row.observedInstructionTokens else { return nil }
        let total = referenceEncoding == nil ? Optional(summary.estimatedTokens) : summary.referenceTokens
        guard let total, total > 0, count >= 0, count <= total else { return nil }
        return Double(count) / Double(total) * 100
    }

    public static var errorStatusExplanation: String {
        tr("Error proportions exclude missing results and unknown error statuses; they do not measure task success. An explicit error may be an unmet assertion, not a service fault; inspect the task evidence before judging tool quality.")
    }

    public static var explanation: String {
        tr("Observed local log records only. Call/result elapsed time includes host overhead; overlapping calls are not wall-clock totals. Returned-text tokens are estimates, not billed usage. Request tokens are separate and never charged to individual tools. Script-wrapped MCP calls, implicit Skill reads, images and missing logs cannot be fully attributed.")
    }
}
