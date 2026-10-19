import Foundation
import ThermoL10n

/// App-reported labels only. Never searches prose, arguments or arbitrary nested data.
enum MCPErrorCodeObservation {
    private static let pattern = try! NSRegularExpression(pattern: #"\A[A-Za-z][A-Za-z0-9_-]{0,63}\z"#)

    static func code(in value: Any?) -> String? {
        guard let result = object(value), ToolUsageParser.boolean(result["isError"]) == true else { return nil }
        var candidates: [Any] = []
        if let structured = result["structuredContent"] as? [String: Any] {
            if let code = structured["code"], !(code is NSNull) { candidates.append(code) }
            // Known CLI bridge envelope; a business object's response.code is not enough.
            if structured["exitCode"] != nil, structured["stdout"] is String, structured["stderr"] is String,
               let response = structured["response"] as? [String: Any], let code = cliCode(response) {
                candidates.append(code)
            }
        }
        if let content = result["content"] as? [[String: Any]] {
            guard content.count <= 64 else { return nil }
            for block in content where block["type"] as? String == "text" {
                guard let text = block["text"] as? String else { continue }
                guard text.utf8.count <= 262_144 else { return nil }
                if let response = object(text), let code = cliCode(response) { candidates.append(code) }
            }
        }
        var labels = Set<String>()
        for candidate in candidates {
            guard let value = safeLabel(candidate) else { return nil }
            labels.insert(value)
        }
        return labels.count == 1 ? labels.first : nil
    }

    static func safeLabel(_ value: Any) -> String? {
        guard let value = value as? String, value.utf8.count <= 64, Redact.text(value) == value,
              pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil else { return nil }
        return value
    }

    private static func cliCode(_ object: [String: Any]) -> Any? {
        guard ToolUsageParser.boolean(object["success"]) == false,
              let error = object["error"] as? String, !error.isEmpty,
              let code = object["code"], !(code is NSNull) else { return nil }
        return code
    }

    private static func object(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        guard let text = value as? String, text.utf8.count <= 1_048_576,
              text.first(where: { !$0.isWhitespace }) == "{", let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

extension ToolUsageRow {
    /// Includes missing/unsupported/conflicting codes and labels excluded by the category limit.
    public var unclassifiedResultErrors: Int? {
        guard kind == "mcp", knownStatusResults != nil, let counts = reportedErrorCodes else { return nil }
        guard counts.keys.allSatisfy({ MCPErrorCodeObservation.safeLabel($0) == $0 }) else { return nil }
        var classified = 0
        for count in counts.values {
            guard count > 0 else { return nil }
            let sum = classified.addingReportingOverflow(count)
            guard !sum.overflow else { return nil }
            classified = sum.partialValue
        }
        guard classified <= reportedErrors else { return nil }
        return reportedErrors - classified
    }

    public var mcpErrorCodeSummary: String? {
        guard kind == "mcp", reportedErrors > 0 else { return nil }
        guard let counts = reportedErrorCodes, let unclassified = unclassifiedResultErrors else {
            return tr("Tool error-code observations are unavailable or inconsistent; analyze again.")
        }
        let sorted = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        var detail = sorted.prefix(6).map { $0.key + " × " + String($0.value) }.joined(separator: " · ")
        if detail.isEmpty { detail = tr("None recognized") }
        if sorted.count > 6 { detail += " · " + tr("%1$@ more code categories in JSON", String(sorted.count - 6)) }
        var text = tr("Tool-reported error codes: %1$@ · unclassified explicit errors %2$@", detail, String(unclassified))
        if errorCodeCategoriesLimited == true { text += "\n" + tr("Error-code category limit reached; remaining errors stay unclassified.") }
        return text
    }
}
