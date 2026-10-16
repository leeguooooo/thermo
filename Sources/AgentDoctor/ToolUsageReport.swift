import Foundation
import ThermoL10n

public struct ToolUsageRow: Codable, Identifiable, Sendable {
    public var id: String
    public var host: String
    public var kind: String
    public var server: String?
    public var name: String
    public var calls = 0
    public var completed = 0
    public var reportedErrors = 0
    public var unknownErrorStatus = 0
    public var missingResults = 0
    public var timingSamples = 0
    public var totalObservedSeconds: Double? = nil
    public var medianSeconds: Double?
    /// Nearest-rank P95, only when at least 20 valid call/result pairs exist.
    public var p95Seconds: Double?
    public var returnedTextBytes = 0
    public var returnedTextEstimatedTokens = 0
    public var nonTextBlocks = 0
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
    public var unmatchedResults = 0
    public var missingTimestamps = 0
    public var unsupportedUsageRecords = 0
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
    public var note: String
    public var returnedTextEstimator: String? = "ascii4-unicode1-v1"

    public static var explanation: String {
        tr("Observed local log records only. Call/result elapsed time includes host overhead; overlapping calls are not wall-clock totals. Returned-text tokens are estimates, not billed usage. Request tokens are separate and never charged to individual tools. Script-wrapped MCP calls, implicit Skill reads, images and missing logs cannot be fully attributed.")
    }
}
