import Foundation
import CoreFoundation
import ThermoL10n

/// Latest host-reported cumulative counters, never a window delta or a request.
/// Session identities are hashed; counters from different sessions are not summed.
public struct CumulativeTokenSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var host: String
    public var observedAt: Date
    public var inputTokens: Int?
    public var cachedInputTokens: Int?
    public var cacheWriteInputTokens: Int?
    public var outputTokens: Int?
    public var reasoningOutputTokens: Int?
    public var conflictingLatestRecords = false

    public var displayLines: [String] {
        func count(_ value: Int?) -> String {
            value.map { $0.formatted(.number.locale(Locale(identifier: "en_US"))) } ?? tr("Unknown")
        }
        var lines = [tr("Session %1$@ · observed %2$@", String(id.prefix(8)), ISO8601DateFormatter().string(from: observedAt))]
        if conflictingLatestRecords {
            lines.append(tr("Conflicting cumulative counters at the latest timestamp; values are unknown."))
        } else {
            lines.append(tr("Input %1$@ · output %2$@ tokens", count(inputTokens), count(outputTokens)))
            lines.append(tr("Cached input %1$@ · cache creation %2$@ · reasoning output %3$@; not additional totals.", count(cachedInputTokens), count(cacheWriteInputTokens), count(reasoningOutputTokens)))
        }
        return lines
    }
}

extension ToolUsageReport {
    public static var cumulativeTokenExplanation: String {
        tr("Latest reported cumulative counters per observed session. May include earlier or inherited usage. Separate from window/request/tool totals and billing; sessions are not summed.")
    }
}

extension ToolUsageParser {
    mutating func cumulativeTokens(session: String, object: [String: Any]?, time: Date?) {
        guard let time else { coverage.unsupportedUsageRecords += 1; return }
        guard inWindow(time) else { return }
        guard let object, !session.isEmpty, session.count <= 512 else { coverage.unsupportedUsageRecords += 1; return }
        func integer(_ key: String) -> Int? {
            guard let value = object[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue >= 0,
                  value.doubleValue < Double(Int.max / 1_000_000), value.doubleValue.rounded() == value.doubleValue else { return nil }
            return value.intValue
        }
        guard let input = integer("input_tokens"), let output = integer("output_tokens") else { coverage.unsupportedUsageRecords += 1; return }
        let id = Self.identity("codex|cumulative|" + session)
        guard cumulativeSnapshots.count < 50_000 || cumulativeSnapshots[id] != nil else { coverage.limitReached = true; return }
        var value = CumulativeTokenSnapshot(id: id, host: "codex", observedAt: time, inputTokens: input,
            cachedInputTokens: integer("cached_input_tokens").flatMap { $0 <= input ? $0 : nil },
            cacheWriteInputTokens: integer("cache_write_input_tokens"), outputTokens: output,
            reasoningOutputTokens: integer("reasoning_output_tokens").flatMap { $0 <= output ? $0 : nil })
        if let previous = cumulativeSnapshots[id] {
            guard previous.observedAt <= time else { return }
            if previous.observedAt == time {
                guard previous != value else { return }
                // Preserve ambiguity instead of choosing the larger or last-read value.
                value.inputTokens = nil; value.cachedInputTokens = nil; value.cacheWriteInputTokens = nil
                value.outputTokens = nil; value.reasoningOutputTokens = nil; value.conflictingLatestRecords = true
            }
        }
        cumulativeSnapshots[id] = value
    }
}
