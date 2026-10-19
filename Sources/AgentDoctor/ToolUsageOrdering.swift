import Foundation
import ThermoL10n

/// Display order for observed content or call intervals, never request or billing usage.
public enum ToolUsageOrdering: String, Codable, Sendable {
    case text, structured, time

    public func count(for row: ToolUsageRow) -> Int? {
        let value: Int?
        switch self {
        case .text:
            value = row.referenceEncoding == nil ? row.returnedTextEstimatedTokens : row.referenceReturnedTextTokens
        case .structured:
            value = row.observedStructuredJSONTokens
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
        case .structured:
            return tr("Ranks structured JSON reference or estimated tokens only when completed result envelopes were fully inspectable. Unknown entries follow known values; this is not model usage.")
        }
    }
}
