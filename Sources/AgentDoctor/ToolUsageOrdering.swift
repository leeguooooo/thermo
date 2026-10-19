import Foundation
import ThermoL10n

/// Display order for observed content or call intervals, never request or billing usage.
public enum ToolUsageOrdering: String, Codable, Sendable {
    case text, structured, time, errors, instructions

    public func count(for row: ToolUsageRow) -> Int? {
        let value: Int?
        switch self {
        case .text:
            value = row.referenceEncoding == nil ? row.returnedTextEstimatedTokens : row.referenceReturnedTextTokens
        case .structured:
            value = row.observedStructuredJSONTokens
        case .instructions:
            guard row.kind == "skill" else { return nil }
            value = row.observedInstructionTokens
        case .errors:
            guard row.calls > 0, row.completed >= 0, row.completed <= row.calls,
                  row.knownStatusResults != nil, let failures = row.invocationFailures,
                  failures >= 0, failures <= row.calls - row.completed else { return nil }
            // Result errors and failed invocations are disjoint observations.
            // The guards bound their sum by calls, preventing overflow.
            value = row.reportedErrors + failures
        case .time: return nil
        }
        return value.flatMap { $0 >= 0 ? $0 : nil }
    }

    /// Valid observed interval sums only; incomplete timing coverage remains explicit in each row.
    public static func observedSeconds(for row: ToolUsageRow) -> Double? {
        guard row.calls >= 0, row.timingSamples > 0, row.timingSamples <= row.calls,
              let seconds = row.totalObservedSeconds, seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    public func sorted(_ rows: [ToolUsageRow]) -> [ToolUsageRow] {
        rows.sorted {
            if self == .time {
                let left = Self.observedSeconds(for: $0), right = Self.observedSeconds(for: $1)
                if left == right { return $0.id < $1.id }
                guard let left else { return false }
                guard let right else { return true }
                return left > right
            }
            let left = count(for: $0) ?? -1, right = count(for: $1) ?? -1
            return left == right ? $0.id < $1.id : left > right
        }
    }

    public var explanation: String {
        switch self {
        case .text:
            return tr("Ranks observed returned-text reference or estimated tokens. Unknown counts follow known values; this is not request usage.")
        case .time:
            return tr("Ranks summed valid observed call intervals; overlaps count per call. Unknown timing follows known values. Missing intervals are excluded; this is not task duration.")
        case .errors:
            return tr("Ranks observed explicit result errors plus host-reported invocation failures. Unmeasured or invalid counts follow known values. Missing results and unknown result statuses are not counted as errors; this is not a failure rate or service quality score.")
        case .structured:
            return tr("Ranks structured JSON reference or estimated tokens only when completed result envelopes were fully inspectable. Unknown entries follow known values; this is not model usage.")
        case .instructions:
            return tr("Ranks observed source-linked Skill instruction text. Unknown or incomplete loading follows known counts; this is not total Skill loading, request usage or billing.")
        }
    }
}
