import Foundation

/// Sparkle-style build ordering, implemented without linking Sparkle into the CLI.
/// Numeric runs do not pass through a fixed-width integer, including very large build IDs.
public enum UpdateVersion {
    private enum Kind: Equatable { case number, word, period, separator }
    private struct Part {
        var value: String
        var kind: Kind
    }

    private static func parts(_ text: String) -> [Part]? {
        guard !text.isEmpty, text.utf8.count <= 128, text.allSatisfy({ $0.isASCII && !$0.isNewline && !$0.isASCIIControl }),
              text.contains(where: { $0.isNumber }), text.first?.isLetter == true || text.first?.isNumber == true else { return nil }
        var result: [Part] = []
        for ch in text {
            if ch == "-" { break } // Sparkle ignores a dash suffix (not a SemVer comparator).
            let kind: Kind
            if ch.isNumber { kind = .number }
            else if ch == "." { kind = .period }
            else if ch.isWhitespace || ch.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) }) { kind = .separator }
            else { kind = .word }
            if [.number, .word].contains(kind), result.last?.kind == kind { result[result.count - 1].value.append(ch) }
            else { result.append(Part(value: String(ch), kind: kind)) }
        }
        return result
    }

    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard var a = parts(lhs), var b = parts(rhs) else { return nil }
        let ac = a.prefix { $0.kind == .number || $0.kind == .period }.count
        let bc = b.prefix { $0.kind == .number || $0.kind == .period }.count
        if ac < bc { a.insert(contentsOf: b[ac..<bc].map { Part(value: $0.kind == .number ? "0" : ".", kind: $0.kind) }, at: ac) }
        if bc < ac { b.insert(contentsOf: a[bc..<ac].map { Part(value: $0.kind == .number ? "0" : ".", kind: $0.kind) }, at: bc) }
        for (left, right) in zip(a, b) {
            if left.kind == .number, right.kind == .number {
                let l = left.value.drop(while: { $0 == "0" }), r = right.value.drop(while: { $0 == "0" })
                if l.count != r.count { return l.count < r.count ? .orderedAscending : .orderedDescending }
                if l != r { return l.lexicographicallyPrecedes(r) ? .orderedAscending : .orderedDescending }
            } else if left.kind == .word, right.kind == .word {
                let order = left.value.compare(right.value)
                if order != .orderedSame { return order }
            } else if left.kind != right.kind {
                if left.kind == .word { return .orderedAscending }
                if right.kind == .word { return .orderedDescending }
                if left.kind == .number { return .orderedDescending }
                if right.kind == .number { return .orderedAscending }
                // All non-word, non-numeric separators compare equally.
            }
        }
        if a.count == b.count { return .orderedSame }
        let common = min(a.count, b.count)
        let extra = a.count > b.count ? a[common] : b[common]
        let longerWins = extra.kind != .word
        return (a.count > b.count) == longerWins ? .orderedDescending : .orderedAscending
    }
}

private extension Character {
    var isASCIIControl: Bool { unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
}
