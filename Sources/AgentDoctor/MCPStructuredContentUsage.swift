import Foundation
import ThermoL10n

/// The compact JSON representation of structuredContent as logged, separate from returned text.
/// It may duplicate text or contain encoded media. It is never request or billing usage.
public struct MCPStructuredContentUsage: Codable, Sendable {
    public var inspectedResultObjects = 0
    public var unobservableResults = 0
    public var structuredResults = 0
    public var alongsideContentResults = 0
    public var jsonBytes = 0
    public var jsonEstimatedTokens = 0
    public var jsonReferenceTokens: Int?
    public var unavailableJSONResults = 0

    init(encoding: TextEncoding) { jsonReferenceTokens = encoding == .heuristic ? nil : 0 }

    mutating func record(_ observation: MCPStructuredResultObservation) {
        switch observation {
        case .unobservable: unobservableResults += 1
        case .absent: inspectedResultObjects += 1
        case let .present(text, alongsideContent):
            inspectedResultObjects += 1; structuredResults += 1
            if alongsideContent { alongsideContentResults += 1 }
            guard let text else {
                unavailableJSONResults += 1; jsonReferenceTokens = nil; return
            }
            jsonBytes += text.bytes; jsonEstimatedTokens += text.estimatedTokens
            if let total = jsonReferenceTokens, let count = text.referenceTokens { jsonReferenceTokens = total + count }
            else { jsonReferenceTokens = nil }
        }
    }
}

/// Inspects only the result envelope, never text blocks, arguments, or nested script outputs.
enum MCPStructuredResultObservation {
    case unobservable
    case absent
    case present(TextFootprint?, alongsideContent: Bool)

    init(_ value: Any?, encoding: TextEncoding) {
        let object: [String: Any]
        if let direct = value as? [String: Any] { object = direct }
        else if let string = value as? String, string.first(where: { !$0.isWhitespace }) == "{",
                let data = string.data(using: .utf8),
                let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                parsed["content"] is [[String: Any]] || parsed["structuredContent"] != nil { object = parsed }
        else { self = .unobservable; return }
        guard let structured = object["structuredContent"] else { self = .absent; return }
        let alongside = object["content"] != nil
        // MCP structuredContent must be an object. Malformed fields are not measured as empty.
        guard let structured = structured as? [String: Any], JSONSerialization.isValidJSONObject(structured),
              let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            self = .present(nil, alongsideContent: alongside); return
        }
        self = .present(TextFootprint(String(decoding: data, as: UTF8.self), encoding: encoding), alongsideContent: alongside)
    }
}

extension ToolUsageRow {
    public var mcpStructuredContentLines: [String] {
        guard kind == "mcp" else { return [] }
        guard let usage = structuredContent else {
            return [tr("Structured result envelopes were not checked in this report; analyze again.")]
        }
        var lines = [tr("Structured result coverage: %1$@ envelopes checked · %2$@ results not inspectable · %3$@ structured fields · %4$@ invalid fields",
                        String(usage.inspectedResultObjects), String(usage.unobservableResults), String(usage.structuredResults), String(usage.unavailableJSONResults))]
        if usage.structuredResults > 0 {
            let tokens = referenceEncoding == nil ? "≈" + String(usage.jsonEstimatedTokens) : usage.jsonReferenceTokens.map(String.init) ?? tr("Unknown")
            lines.append(tr("Measured structured JSON: %1$@ bytes / %2$@ tokens · %3$@ results also contain content", String(usage.jsonBytes), tokens, String(usage.alongsideContentResults)))
            lines.append(tr("JSON representation may overlap returned text or include encoded media. Do not add the totals or infer model usage."))
        } else if usage.unobservableResults > 0 {
            lines.append(tr("Uninspectable results do not establish that structured content was absent."))
        }
        return lines
    }
}
