import Foundation

/// Describes text as logged. Never unwraps it for accounting, decodes media, or changes error status.
struct ToolResultTextObservation {
    var serializedMedia = false
    var truncationMarker = false

    init() {}
    init(_ value: Any?, codexInputBlocks: Bool) {
        inspectResult(value, codexInputBlocks: codexInputBlocks, depth: 0)
    }

    private static let marker = try! NSRegularExpression(
        pattern: #"…[1-9][0-9]{0,11} chars truncated…|Warning: truncated output \(original token count: [1-9][0-9]{0,11}\)"#)
    private static let contextLimitMarker = "Output exceeded the available model context and was truncated."

    private static func json(_ text: String) -> Any? {
        guard let first = text.first(where: { !$0.isWhitespace }), first == "{" || first == "[",
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private mutating func inspectText(_ text: String) {
        if Self.marker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            || text.contains(Self.contextLimitMarker) {
            truncationMarker = true
        }
        if let value = Self.json(text), Self.containsMedia(value, depth: 0) { serializedMedia = true }
    }

    /// Follows the existing result/outer-result text extraction contract, rather than scanning arguments.
    private mutating func inspectResult(_ value: Any?, codexInputBlocks: Bool, depth: Int) {
        guard depth < 5 else { return }
        if let text = value as? String {
            if text.first == "{", let object = Self.json(text) as? [String: Any],
               object["content"] is [[String: Any]] || object["structuredContent"] != nil {
                inspectResult(object, codexInputBlocks: codexInputBlocks, depth: depth + 1)
            } else if codexInputBlocks, let blocks = Self.json(text) as? [[String: Any]], !blocks.isEmpty,
                      blocks.allSatisfy({ ($0["type"] as? String)?.hasPrefix("input_") == true }),
                      blocks.contains(where: { ["input_text", "input_image", "input_audio", "input_file", "input_video"].contains($0["type"] as? String ?? "") }) {
                inspectResult(blocks, codexInputBlocks: true, depth: depth + 1)
            } else { inspectText(text) }
        } else if let blocks = value as? [[String: Any]] {
            for block in blocks where block["type"] as? String == "text" || (codexInputBlocks && block["type"] as? String == "input_text") {
                if let text = block["text"] as? String { inspectText(text) }
            }
        } else if let object = value as? [String: Any] {
            if let content = object["content"] {
                inspectResult(content, codexInputBlocks: codexInputBlocks, depth: depth + 1)
            } else if let structured = object["structuredContent"],
                      let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys, .fragmentsAllowed]) {
                inspectText(String(decoding: data, as: UTF8.self))
            }
        }
    }

    private static func containsMedia(_ value: Any, depth: Int) -> Bool {
        guard depth < 5 else { return false }
        if let blocks = value as? [[String: Any]] {
            return blocks.contains { containsMedia($0, depth: depth + 1) }
        }
        guard let object = value as? [String: Any] else { return false }
        if let type = object["type"] as? String, ["image", "audio"].contains(type),
           object["data"] is String, object["mimeType"] is String { return true }
        if let content = object["content"] { return containsMedia(content, depth: depth + 1) }
        return false
    }
}
