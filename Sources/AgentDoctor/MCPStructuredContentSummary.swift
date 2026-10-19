import Foundation
import ThermoL10n

/// A separate representation total for directly attributed MCP results in selected logs.
/// Unknown envelopes, missing replies, and incomplete log reading never become zero.
public struct MCPStructuredContentSummary: Codable, Equatable, Sendable {
    public let referenceEncoding: String?
    public let logReadingComplete: Bool
    public let completedResults: Int?
    public let checkedEnvelopes: Int?
    public let structuredResults: Int?
    public let unobservableResults: Int?
    public let unmeasurableFields: Int?
    public let missingResults: Int?
    public let invocationFailures: Int?
    public let uncheckedRows: Int
    public let inconsistentRows: Int
    public let knownJSONBytes: Int?
    public let knownJSONTokens: Int?
    public let totalJSONBytes: Int?
    public let totalJSONTokens: Int?

    init(rows allRows: [ToolUsageRow], encoding: String?, logComplete: Bool) {
        referenceEncoding = encoding; logReadingComplete = logComplete
        let rows = allRows.filter { $0.kind == "mcp" }
        let duplicateIDs = Set(Dictionary(grouping: rows, by: \.id).filter { $0.value.count > 1 }.keys)
        var known: [MCPStructuredContentUsage] = []
        var unchecked = 0, inconsistent = 0
        for row in rows {
            guard !duplicateIDs.contains(row.id), row.calls >= 0, row.completed >= 0,
                  row.completed <= row.calls, row.missingResults >= 0, row.missingResults <= row.calls,
                  row.referenceEncoding == encoding else { inconsistent += 1; continue }
            guard let failures = row.invocationFailures, let usage = row.structuredContent else { unchecked += 1; continue }
            guard failures >= 0, failures <= row.calls,
                  usage.inspectedResultObjects >= 0, usage.inspectedResultObjects <= row.completed,
                  usage.unobservableResults == row.completed - usage.inspectedResultObjects,
                  usage.structuredResults >= 0, usage.structuredResults <= usage.inspectedResultObjects,
                  usage.alongsideContentResults >= 0, usage.alongsideContentResults <= usage.structuredResults,
                  usage.unavailableJSONResults >= 0, usage.unavailableJSONResults <= usage.structuredResults,
                  usage.jsonBytes >= 0, usage.jsonEstimatedTokens >= 0,
                  usage.jsonReferenceTokens.map({ $0 >= 0 }) ?? true,
                  usage.structuredResults != usage.unavailableJSONResults
                    || (usage.jsonBytes == 0 && usage.jsonEstimatedTokens == 0 && (usage.jsonReferenceTokens ?? 0) == 0)
            else { inconsistent += 1; continue }
            known.append(usage)
        }
        uncheckedRows = unchecked; inconsistentRows = inconsistent
        completedResults = inconsistent == 0 ? Self.sum(rows.map { $0.completed }) : nil
        missingResults = inconsistent == 0 ? Self.sum(rows.map { $0.missingResults }) : nil
        invocationFailures = inconsistent == 0 ? Self.sum(rows.map(\.invocationFailures)) : nil
        checkedEnvelopes = Self.sum(known.map { $0.inspectedResultObjects })
        structuredResults = Self.sum(known.map { $0.structuredResults })
        unobservableResults = Self.sum(known.map { $0.unobservableResults })
        unmeasurableFields = Self.sum(known.map { $0.unavailableJSONResults })
        knownJSONBytes = Self.sum(known.map { $0.jsonBytes })
        knownJSONTokens = Self.sum(known.map { encoding == nil ? $0.jsonEstimatedTokens : $0.jsonReferenceTokens })
        let complete = logComplete && (completedResults ?? 0) > 0 && unchecked == 0 && inconsistent == 0
            && missingResults == 0 && invocationFailures == 0 && unobservableResults == 0 && unmeasurableFields == 0
        totalJSONBytes = complete ? knownJSONBytes : nil
        totalJSONTokens = complete ? knownJSONTokens : nil
    }

    private static func sum(_ values: [Int?]) -> Int? {
        var total = 0
        for value in values {
            guard let value, value >= 0 else { return nil }
            let next = total.addingReportingOverflow(value)
            guard !next.overflow else { return nil }
            total = next.partialValue
        }
        return total
    }

    public var displayLines: [String] {
        func count(_ value: Int?) -> String { value.map(String.init) ?? tr("Unknown") }
        func tokens(_ value: Int?) -> String { value.map { (referenceEncoding == nil ? "≈" : "") + String($0) } ?? tr("Unknown") }
        var lines = [tr("Observed MCP structured JSON coverage: %1$@/%2$@ completed envelopes checked · %3$@ structured fields · %4$@ uninspectable results · %5$@ unmeasurable fields",
                        count(checkedEnvelopes), count(completedResults), count(structuredResults), count(unobservableResults), count(unmeasurableFields))]
        if missingResults != 0 || invocationFailures != 0 || uncheckedRows > 0 || inconsistentRows > 0 {
            lines.append(tr("Missing replies %1$@ · invocation failures %2$@ · rows without coverage %3$@ · inconsistent rows %4$@",
                            count(missingResults), count(invocationFailures), String(uncheckedRows), String(inconsistentRows)))
        }
        if totalJSONBytes == nil || totalJSONTokens == nil {
            lines.append(tr("Known measured MCP structured JSON subset: %1$@ bytes / %2$@ tokens", count(knownJSONBytes), tokens(knownJSONTokens)))
        }
        lines.append(tr("Observed MCP structured JSON total within selected logs: %1$@ bytes / %2$@ tokens", count(totalJSONBytes), tokens(totalJSONTokens)))
        if totalJSONBytes == nil || totalJSONTokens == nil {
            lines.append(tr("Incomplete logs, result coverage or counts leave the full JSON total unknown; the known subset does not fill gaps."))
        }
        lines.append(Self.explanation)
        lines.append(tr("JSON value measurement does not infer the negotiated protocol or validate an output schema."))
        return lines
    }

    public static var explanation: String {
        tr("Separate JSON representation of structuredContent in directly attributed MCP results, including hidden rows. It may overlap returned text or contain encoded media; do not add totals or infer model usage.")
    }
    public static var unavailableExplanation: String {
        tr("Structured JSON totals were not checked or do not match the report rows; analyze again.")
    }
}
