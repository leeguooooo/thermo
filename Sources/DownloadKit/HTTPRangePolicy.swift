import Foundation

public enum HTTPRangePolicy {
    public struct ContentRange: Sendable, Equatable {
        public var start: Int64
        /// Inclusive, as on the wire.
        public var end: Int64
        public var total: Int64?
    }

    /// Parses `bytes <first>-<last>/<total|*>`, rejecting ranges that contradict themselves.
    public static func parse(_ value: String?) -> ContentRange? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count > 5, text.prefix(5).lowercased() == "bytes" else { return nil }
        let rest = text.dropFirst(5)
        guard rest.first?.isWhitespace == true else { return nil }
        let parts = rest.drop { $0.isWhitespace }.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = digits(bounds[0]), let end = digits(bounds[1]) else { return nil }
        var total: Int64?
        if parts[1] != "*" {
            guard let parsed = digits(parts[1]) else { return nil }
            total = parsed
        }
        if end < start { return nil }
        if let total, end >= total { return nil }
        return ContentRange(start: start, end: end, total: total)
    }

    /// `end` is inclusive; nil accepts any end for an open-ended request.
    public static func matches(_ value: String?, start: Int64, end: Int64?) -> Bool {
        guard let range = parse(value), range.start == start else { return false }
        return end == nil || range.end == end
    }

    private static func digits(_ text: Substring) -> Int64? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int64(text)
    }
}
