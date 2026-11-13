import Foundation

/// A page of cleanup candidates judged at once, so the AI can tick for the user. Facts only: the
/// item's name, kind, size, last use, Thermo's own safety rating and note, and a few paths. The
/// answer only ticks; nothing is removed until the user presses Clean, and Thermo's guards
/// (locked, risky, protected locations) still decide what can be ticked at all.
public struct LocalAICleanQuestion: Sendable {
    public struct Item: Sendable, Hashable {
        public var id: String
        public var title: String
        public var detail: String
        public var safety: Safety
        public var bytes: Int64
        public var lastUsed: Date?
        public var note: String?
        public var paths: [String]
        public var locked: String?
        public init(id: String, title: String, detail: String = "", safety: Safety, bytes: Int64, lastUsed: Date? = nil,
                    note: String? = nil, paths: [String] = [], locked: String? = nil) {
            self.id = id; self.title = title; self.detail = detail; self.safety = safety; self.bytes = bytes
            self.lastUsed = lastUsed; self.note = note; self.paths = paths; self.locked = locked
        }
        public init(_ i: CleanItem) {
            self.init(id: i.id, title: i.title, detail: i.detail, safety: i.safety, bytes: i.bytes, lastUsed: i.lastUsed,
                      note: i.note, paths: i.paths, locked: i.blocked)
        }
    }

    public static let limit = 60
    public var category: String
    /// Biggest first, at most `limit`; the key sent for item n is "k<n+1>".
    public var items: [Item]
    public var now: Date
    public var home: String

    public init(category: String, items: [Item], now: Date = Date(), home: String = NSHomeDirectory()) {
        self.category = category
        self.items = Array(items.sorted { $0.bytes > $1.bytes }.prefix(Self.limit))
        self.now = now; self.home = home
    }

    func tilde(_ p: String) -> String { p == home ? "~" : p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p }

    static func age(_ d: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 3600 { return "\(Int(s / 60)) minutes ago" }
        if s < 86400 { return "\(Int(s / 3600)) hours ago" }
        return "\(Int(s / 86400)) days ago"
    }

    /// Exactly what is sent.
    public var facts: String {
        let size = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        var lines = ["Category: \(category)", "Items:"]
        for (n, i) in items.enumerated() {
            var parts = [size(i.bytes), "Thermo rates it \(i.safety.rawValue)"]
            if !i.detail.isEmpty { parts.insert(i.detail, at: 0) }
            if let u = i.lastUsed { parts.append("last used \(Self.age(u, now: now))") }
            if let note = i.note, !note.isEmpty { parts.append("note: \(note)") }
            if let l = i.locked { parts.append("locked: \(l)") }
            let shown = i.paths.prefix(3).map(tilde)
            if !shown.isEmpty { parts.append("paths: " + shown.joined(separator: ", ") + (i.paths.count > 3 ? ", … (\(i.paths.count - 3) more)" : "")) }
            lines.append("- [k\(n + 1)] \(i.title) (" + parts.joined(separator: "; ") + ")")
        }
        return lines.joined(separator: "\n")
    }
}

public struct LocalAICleanAnswer: Sendable, Equatable {
    public var summary: String
    /// Item id → verdict; items the AI skipped are absent.
    public var verdicts: [String: LocalAIAnswer]
    public var source: String
}

extension LocalAI {
    static let cleanSystem = """
    You help someone pick which cleanup candidates on their Mac are safe to remove. A cleanup tool found them \
    and rates each: "safe" (regenerates by itself: caches, logs, build output), "review" (probably unneeded user data), \
    "risky" (could lose work). You get facts only, never file contents. Judge EVERY item by its key. \
    Reply with ONLY a JSON object: {"summary": "<one or two sentences>", \
    "items": [{"key": "k1", "verdict": "delete" | "careful" | "keep", "reason": "<one short sentence>"}]}. \
    "delete": removing it now loses nothing that cannot be rebuilt or downloaded again, and nobody is using it right now. \
    "careful": probably fine, but say what to check first — for example build output of a project used in the last few hours \
    (rebuilding costs time), or data that might matter to the person. "keep": personal data, settings, source, \
    anything that cannot come back, or anything the tool rates risky. When unsure, say "careful", not "delete". Be concrete and brief.
    """

    /// One request for a page of items: a verdict per item, matched back by key.
    public static func pick(_ q: LocalAICleanQuestion, using backend: LocalAIBackend, session: URLSession = .shared) async throws -> LocalAICleanAnswer {
        let lang = Locale.preferredLanguages.first ?? "en"
        let raw = try await send(system: cleanSystem, user: q.facts + "\n\nWrite summary and reasons in the language with code \(lang).",
                                 using: backend, maxTokens: 8000, session: session)
        guard let answer = parsePick(raw, question: q, source: backend.label) else { throw LocalAIError.emptyAnswer }
        return answer
    }

    /// Keeps only verdicts for keys that were asked about; unknown keys are dropped, never invented.
    public static func parsePick(_ raw: String, question q: LocalAICleanQuestion, source: String) -> LocalAICleanAnswer? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        struct Item: Decodable { var key: String; var verdict: String; var reason: String }
        struct Wire: Decodable { var summary: String?; var items: [Item] }
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              let w = try? JSONDecoder().decode(Wire.self, from: Data(text[a...b].utf8)) else { return nil }
        var verdicts: [String: LocalAIAnswer] = [:]
        for i in w.items {
            let key = i.key.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
            guard key.hasPrefix("k"), let n = Int(key.dropFirst()), n >= 1, n <= q.items.count else { continue }
            let id = q.items[n - 1].id
            guard verdicts[id] == nil else { continue }
            verdicts[id] = LocalAIAnswer(verdict: LocalAIAnswer.Verdict(rawValue: i.verdict.lowercased()) ?? .careful,
                                         reason: i.reason, how: nil, source: source)
        }
        guard !verdicts.isEmpty else { return nil }
        return LocalAICleanAnswer(summary: w.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", verdicts: verdicts, source: source)
    }

    /// What the AI may tick: only items it called "delete" that Thermo would let the user tick in bulk
    /// and does not rate risky. Everything else stays as the user left it.
    public static func picks(_ answer: LocalAICleanAnswer, items: [CleanItem]) -> [String] {
        items.filter { i in
            answer.verdicts[i.id]?.verdict == .delete && i.bulkSelectable && i.safety != .risky
        }.map(\.id)
    }
}
