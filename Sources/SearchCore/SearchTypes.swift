import Foundation
import Darwin

public enum SearchItemKind: String, Codable, Sendable { case application, file, folder }

public enum SearchPaths {
    /// Foundation's resolvingSymlinks can rewrite /private/var back to /var; FSEvents uses physical paths.
    public static func canonical(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parent = path, suffix: [String] = []
        while true {
            if let pointer = realpath(parent, nil) {
                let physical = String(cString: pointer); free(pointer)
                return suffix.reversed().reduce(physical) { childrenPrefix($0) + $1 }
            }
            guard parent != "/", !parent.isEmpty else { return path }
            suffix.append((parent as NSString).lastPathComponent)
            parent = (parent as NSString).deletingLastPathComponent
        }
    }
    static func entry(_ path: String) -> String {
        guard path.hasPrefix("/"), path != "/" else { return path }
        return childrenPrefix(canonical((path as NSString).deletingLastPathComponent)) + (path as NSString).lastPathComponent
    }
    public static func isWithin(_ path: String, root: String) -> Bool {
        path == root || (root == "/" ? path.hasPrefix("/") : path.hasPrefix(root + "/"))
    }
    static func childrenPrefix(_ path: String) -> String { path == "/" ? "/" : path + "/" }
}

public struct SearchItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public var name: String
    public var kind: SearchItemKind
    public var alternateNames: [String]
    public var modified: TimeInterval
    public var alias: String?
    public var favorite: Bool
    public var visits: Int
    public var lastOpened: TimeInterval
    public init(path: String, name: String, kind: SearchItemKind, alternateNames: [String] = [],
                modified: TimeInterval = 0, alias: String? = nil, favorite: Bool = false,
                visits: Int = 0, lastOpened: TimeInterval = 0) {
        self.path = path; self.name = name; self.kind = kind; self.alternateNames = alternateNames
        self.modified = modified; self.alias = alias; self.favorite = favorite
        self.visits = visits; self.lastOpened = lastOpened
    }
}

public struct SearchRoot: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public var indexedAt: TimeInterval
    public var count: Int
    public var issue: String?
    public var available: Bool
    public init(path: String, indexedAt: TimeInterval = 0, count: Int = 0, issue: String? = nil, available: Bool = true) {
        self.path = path; self.indexedAt = indexedAt; self.count = count; self.issue = issue; self.available = available
    }
}

public struct SearchPreferences: Codable, Sendable, Equatable {
    public var roots: [String] = []
    public var includeHiddenFiles = false
    public var respectIgnoreFiles = true
    public var excludedPatterns: [String] = ["node_modules", ".git", ".build", "DerivedData", "target", "*.tmp", "*.temp", "**/Library/Caches/**", "**/Library/Application Support/**", "**/.cache/**"]
    public init() {}
}

public struct SearchResponse: Codable, Sendable {
    public let schemaVersion: Int
    public var query: String
    public var items: [SearchItem]
    public var roots: [SearchRoot]
    public var complete: Bool
    public var limited: Bool
    public var issues: [String]
    public init(query: String, items: [SearchItem], roots: [SearchRoot] = [], complete: Bool = true, issues: [String] = [], limited: Bool = false) {
        self.schemaVersion = 1
        self.query = query; self.items = items; self.roots = roots; self.complete = complete; self.issues = issues; self.limited = limited
    }
}

public final class SearchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

public enum SearchText {
    public static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func latin(_ text: String) -> String {
        if text.unicodeScalars.allSatisfy({ $0.value < 128 }) { return normalized(text) }
        return normalized(text.applyingTransform(.toLatin, reverse: false) ?? text)
    }
    /// Inverted character/three-character keys admit subsequences and typo candidates without walking the filesystem.
    static func grams(_ text: String) -> String {
        let chars = Array(normalized(text).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        var keys = Set(chars.map { "c" + String($0.value, radix: 16) })
        if chars.count >= 3 {
            for i in 0...(chars.count - 3) { keys.insert("g" + chars[i...i+2].map { String($0.value, radix: 16) }.joined(separator: "x")) }
        }
        return keys.sorted().joined(separator: " ")
    }
    static func matchExpression(_ query: String) -> String? {
        let parts = normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !parts.isEmpty else { return nil }
        return parts.map { part in
            let words = "words : \"" + part.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"
            let keys = grams(part).split(separator: " ").map(String.init)
            let chars = keys.filter { $0.hasPrefix("c") }
            let triples = keys.filter { $0.hasPrefix("g") }
            var alternatives = [words]
            if part.count >= 2 || part.unicodeScalars.contains(where: { $0.value > 127 }), !chars.isEmpty { alternatives.append("grams : (" + chars.joined(separator: " AND ") + ")") }
            if part.count >= 5, !triples.isEmpty { alternatives.append("grams : (" + triples.joined(separator: " OR ") + ")") }
            return "(" + alternatives.joined(separator: " OR ") + ")"
        }.joined(separator: " AND ")
    }
}

/// Independent matching policy: explicit intent precedes learned frequency. No target-app code is used.
public enum SearchRanking {
    public struct Match: Sendable { public let tier: Int; public let quality: Int }
    public static func match(_ item: SearchItem, query: String) -> Match? {
        let q = SearchText.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return Match(tier: 0, quality: 0) }
        if let alias = item.alias, SearchText.normalized(alias) == q { return Match(tier: 100, quality: 0) }
        var best: Match?
        let names = [item.name] + item.alternateNames + [SearchText.latin(item.name)]
        for name in names {
            let n = SearchText.normalized(name)
            let candidate: Match?
            if n == q { candidate = Match(tier: 90, quality: 0) }
            else if n.hasPrefix(q) { candidate = Match(tier: 80, quality: -n.count) }
            else if let range = n.range(of: q) { candidate = Match(tier: 65, quality: -n.distance(from: n.startIndex, to: range.lowerBound)) }
            else if let score = subsequence(q, in: n) { candidate = Match(tier: 50, quality: score) }
            else if q.count >= 4, typo(q, n) { candidate = Match(tier: 40, quality: -n.count) }
            else {
                let terms = q.split(whereSeparator: { $0.isWhitespace })
                candidate = terms.count > 1 && terms.allSatisfy { n.contains($0) } ? Match(tier: 60, quality: -n.count) : nil
            }
            if let candidate, best == nil || (candidate.tier, candidate.quality) > (best!.tier, best!.quality) { best = candidate }
        }
        if let alias = item.alias, SearchText.normalized(alias).hasPrefix(q), best == nil || best!.tier < 75 { best = Match(tier: 75, quality: 0) }
        if best == nil, q.count >= 3, SearchText.normalized((item.path as NSString).deletingLastPathComponent).contains(q) { return Match(tier: 20, quality: 0) }
        return best
    }
    public static func sorted(_ items: [SearchItem], query: String, limit: Int = 50, cancellation: SearchCancellation? = nil) -> [SearchItem] {
        let empty = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let now = Date().timeIntervalSince1970
        var matches: [(SearchItem, Match)] = []
        for item in items {
            if cancellation?.isCancelled == true { return [] }
            if let result = match(item, query: query) { matches.append((item, result)) }
        }
        return matches.sorted { a, b in
            if a.1.tier != b.1.tier { return a.1.tier > b.1.tier }
            if a.0.favorite != b.0.favorite { return a.0.favorite }
            let av = min(18, log2(Double(a.0.visits) + 1) * 3) * pow(0.5, max(0, now - a.0.lastOpened) / (14 * 86400))
            let bv = min(18, log2(Double(b.0.visits) + 1) * 3) * pow(0.5, max(0, now - b.0.lastOpened) / (14 * 86400))
            if !empty {
                let aq = Double(a.1.quality) + av, bq = Double(b.1.quality) + bv
                if aq != bq { return aq > bq }
            }
            if av != bv { return av > bv }
            if a.0.kind != b.0.kind, a.0.kind == .application || b.0.kind == .application { return a.0.kind == .application }
            let order = a.0.name.localizedStandardCompare(b.0.name)
            return order == .orderedSame ? a.0.path < b.0.path : order == .orderedAscending
        }.prefix(max(0, limit)).map(\.0)
    }
    private static func subsequence(_ query: String, in name: String) -> Int? {
        let q = Array(query), n = Array(name)
        guard !q.isEmpty, q.count <= n.count, n.count <= 512 else { return nil }
        var i = 0, score = 0, previous = -2
        for (j, c) in n.enumerated() where i < q.count {
            if c == q[i] {
                score += (j == 0 || !n[j - 1].isLetter && !n[j - 1].isNumber ? 6 : 2) + (j == previous + 1 ? 3 : 0)
                previous = j; i += 1
            }
        }
        return i == q.count ? score - n.count : nil
    }
    private static func typo(_ query: String, _ name: String) -> Bool {
        let stem = (name as NSString).deletingPathExtension
        let words = [stem] + stem.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return words.contains { word in
            let a = Array(query), b = Array(word)
            guard abs(a.count - b.count) <= 1, a.count <= 64, b.count <= 64 else { return false }
            if a.count == b.count {
                let differences = a.indices.filter { a[$0] != b[$0] }
                if differences.count <= 1 { return true }
                if differences.count == 2, differences[1] == differences[0] + 1 { return a[differences[0]] == b[differences[1]] && a[differences[1]] == b[differences[0]] }
                return false
            }
            let shorter = a.count < b.count ? a : b, longer = a.count < b.count ? b : a
            var i = 0, j = 0, edits = 0
            while i < shorter.count && j < longer.count {
                if shorter[i] == longer[j] { i += 1; j += 1 } else { edits += 1; j += 1 }
                if edits > 1 { return false }
            }
            return true
        }
    }
}
