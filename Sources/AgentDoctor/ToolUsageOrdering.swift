import Foundation
import ThermoL10n

/// Display order for observed representations, never request or billing usage.
public enum ToolUsageOrdering: String, Codable, Sendable {
    case text, structured

    public func count(for row: ToolUsageRow) -> Int? {
        let value: Int?
        switch self {
        case .text:
            value = row.referenceEncoding == nil ? row.returnedTextEstimatedTokens : row.referenceReturnedTextTokens
        case .structured:
            value = row.observedStructuredJSONTokens
        }
        return value.flatMap { $0 >= 0 ? $0 : nil }
    }

    public func sorted(_ rows: [ToolUsageRow]) -> [ToolUsageRow] {
        rows.sorted {
            let left = count(for: $0) ?? -1, right = count(for: $1) ?? -1
            return left == right ? $0.id < $1.id : left > right
        }
    }

    public var explanation: String {
        switch self {
        case .text:
            return tr("Ranks observed returned-text reference or estimated tokens. Unknown counts follow known values; this is not request usage.")
        case .structured:
            return tr("Ranks structured JSON reference or estimated tokens only when completed result envelopes were fully inspectable. Unknown entries follow known values; this is not model usage.")
        }
    }
}
