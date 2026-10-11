// Processes, live agent sessions and the protected-path guard are shared with the agent doctor.
@_exported import AgentCore
// User-facing text goes through tr(); the CLI pins English, the app follows the chosen language.
@_exported import ThermoL10n
import Foundation
import CryptoKit

/// What a finding is, for grouping in the CLI and the app.
public enum CleanCategory: String, CaseIterable, Codable, Sendable {
    case aiSessions = "ai-sessions"
    case agentWorktrees = "agent-worktrees"
    case aiModels = "ai-models"
    case aiCaches = "ai-caches"
    case devCaches = "dev-caches"
    case xcode
    case projects
    case browsers
    case system

    public var title: String {
        switch self {
        case .aiSessions: return tr("AI sessions")
        case .agentWorktrees: return tr("Agent worktrees")
        case .aiModels: return tr("AI models")
        case .aiCaches: return tr("AI tool caches")
        case .devCaches: return tr("Developer caches")
        case .xcode: return "Xcode"
        case .projects: return tr("Project build artifacts")
        case .browsers: return tr("Browser caches")
        case .system: return tr("System & apps")
        }
    }

    public var isAI: Bool { [.aiSessions, .agentWorktrees, .aiModels, .aiCaches].contains(self) }
}

/// How sure we are that removing something costs the user nothing.
public enum Safety: String, Codable, Comparable, Sendable {
    /// Regenerated automatically (caches, logs, build output). Removed permanently by default.
    case safe
    /// User data that is probably unneeded (old sessions, models, archives). Moved to the Trash by default.
    case review
    /// Could lose work (dirty worktrees). Never selected by `safe` or `all`; only by exact id.
    case risky

    var rank: Int { self == .safe ? 0 : self == .review ? 1 : 2 }
    public static func < (a: Safety, b: Safety) -> Bool { a.rank < b.rank }
}

/// A piece of an item that can be kept or removed on its own (one session of a project group).
public struct CleanPart: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var bytes: Int64
    public var lastUsed: Date?
    public var paths: [String]

    public init(id: String, title: String, bytes: Int64, lastUsed: Date?, paths: [String]) {
        self.id = id; self.title = title; self.bytes = bytes; self.lastUsed = lastUsed; self.paths = paths
    }
}

/// One thing that can be cleaned: a set of paths removed together.
public struct CleanItem: Codable, Identifiable, Sendable {
    /// Stable across scans, e.g. `xcode-derived-data` or `claude-sessions/-Users-leo-src-app`.
    public var id: String
    public var category: CleanCategory
    public var title: String
    /// Secondary line: project path, model tag, "project folder deleted", …
    public var detail: String
    public var safety: Safety
    public var bytes: Int64
    public var files: Int
    /// Newest modification among the paths, when known.
    public var lastUsed: Date?
    /// Paths removed when this item is cleaned.
    public var paths: [String]
    /// Why some paths were held back or the item cannot be cleaned right now.
    public var note: String?
    /// Set when the item is currently in use (running app, live session); `run` skips it.
    public var blocked: String?
    /// Command to run instead of deleting files (e.g. `docker system prune`). Informational items have no paths.
    public var hint: String?
    /// Shell command to run after the paths are removed (e.g. `git worktree prune`).
    public var afterClean: [String]?
    /// Commands (argv, no shell) that do the removal instead of deleting paths, for things a tool
    /// must remove itself (e.g. `xcrun simctl runtime delete <id>`).
    public var commands: [[String]]?
    /// Separately selectable pieces, newest first; together they make up `paths`.
    public var parts: [CleanPart]?
    /// Items with the same group belong together (build output of one project folder).
    public var group: String?

    public init(id: String, category: CleanCategory, title: String, detail: String = "", safety: Safety,
                bytes: Int64 = 0, files: Int = 0, lastUsed: Date? = nil, paths: [String] = [],
                note: String? = nil, blocked: String? = nil, hint: String? = nil, afterClean: [String]? = nil,
                parts: [CleanPart]? = nil, group: String? = nil, commands: [[String]]? = nil) {
        self.id = id; self.category = category; self.title = title; self.detail = detail; self.safety = safety
        self.bytes = bytes; self.files = files; self.lastUsed = lastUsed; self.paths = paths
        self.note = note; self.blocked = blocked; self.hint = hint; self.afterClean = afterClean; self.parts = parts; self.group = group
        self.commands = commands
    }

    public var cleanable: Bool { blocked == nil && bytes > 0 && (!paths.isEmpty || !(commands ?? []).isEmpty) }

    /// The item narrowed to some of its parts (all of them when `keep` covers every part).
    public func only(_ keep: Set<String>) -> CleanItem {
        guard let parts else { return self }
        let chosen = parts.filter { keep.contains($0.id) }
        var item = self
        item.parts = chosen
        item.paths = chosen.flatMap(\.paths)
        item.bytes = chosen.reduce(0) { $0 + $1.bytes }
        item.files = chosen.count == parts.count ? files : chosen.reduce(0) { $0 + $1.paths.count }
        item.lastUsed = chosen.compactMap(\.lastUsed).max()
        // Session group titles end with their count ("Codex · api · 5 sessions"); keep it truthful.
        if chosen.count != parts.count, let r = title.range(of: " · ", options: .backwards),
           title[r.upperBound...].contains(where: \.isNumber) {
            item.title = title[..<r.upperBound] + trCount(chosen.count, "%1$@ session", "%1$@ sessions")
        }
        return item
    }
}

public struct ScanReport: Codable, Sendable {
    public var items: [CleanItem]
    /// Locations we could not read (usually needs Full Disk Access).
    public var denied: [String]
    public var started: Date
    public var duration: TimeInterval
    /// Claude Code `cleanupPeriodDays` (it prunes its own sessions after this many days; default 30).
    public var claudeCleanupDays: Int?
    /// The scan was stopped before it finished; `items` is what had been found so far.
    public var cancelled: Bool
    /// What the scan covered, so a saved report is only reused for selections it can answer.
    public var categories: [CleanCategory]?
    public var olderThanDays: Int?
    public var projectRoots: [String]?
    public var discoverProjectRoots: Bool?
    /// Titles and notes are written in this language at scan time ("en", "zh-Hans").
    public var language: String?

    public init(items: [CleanItem], denied: [String], started: Date, duration: TimeInterval, claudeCleanupDays: Int? = nil,
                cancelled: Bool = false) {
        self.items = items; self.denied = denied; self.started = started; self.duration = duration
        self.claudeCleanupDays = claudeCleanupDays
        self.cancelled = cancelled
    }

    private enum CodingKeys: String, CodingKey {
        case items, denied, started, duration, claudeCleanupDays, cancelled, categories, olderThanDays, projectRoots, discoverProjectRoots, language
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([CleanItem].self, forKey: .items)
        denied = try c.decode([String].self, forKey: .denied)
        started = try c.decode(Date.self, forKey: .started)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        claudeCleanupDays = try c.decodeIfPresent(Int.self, forKey: .claudeCleanupDays)
        cancelled = try c.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
        categories = try c.decodeIfPresent([CleanCategory].self, forKey: .categories)
        olderThanDays = try c.decodeIfPresent(Int.self, forKey: .olderThanDays)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        projectRoots = try c.decodeIfPresent([String].self, forKey: .projectRoots)
        discoverProjectRoots = try c.decodeIfPresent(Bool.self, forKey: .discoverProjectRoots)
        // Before worktrees had their own category, cached session scans included them.
        let oldWorktrees = items.indices.filter { items[$0].category == .aiSessions && items[$0].id.hasPrefix("worktree/") }
        for i in oldWorktrees { items[i].category = .agentWorktrees }
        if !oldWorktrees.isEmpty, var scope = categories, !scope.contains(.agentWorktrees) {
            scope.append(.agentWorktrees)
            categories = scope
        }
    }

    public var totalBytes: Int64 { items.filter(\.cleanable).reduce(0) { $0 + $1.bytes } }

    public func bytes(in category: CleanCategory) -> Int64 {
        items.filter { $0.category == category && $0.cleanable }.reduce(0) { $0 + $1.bytes }
    }
}

public struct ScanOptions: Sendable {
    /// AI sessions / project artifacts untouched for this many days count as stale.
    public var olderThanDays: Int = 30
    /// Folders searched for project build artifacts and agent worktrees.
    public var projectRoots: [String] = ScanOptions.defaultProjectRoots
    /// Include projects discovered from editor and agent history (disable for an explicit root).
    public var discoverProjectRoots = true
    public var categories: Set<CleanCategory> = Set(CleanCategory.allCases)
    public var home: String = NSHomeDirectory()
    /// Background priority: macOS throttles the scan's CPU and disk I/O so it stays out
    /// of the way (slower). The app uses this; the CLI, where someone waits, does not.
    public var lowPriority = false

    public init() {}

    public static var defaultProjectRoots: [String] { defaultProjectRoots(home: NSHomeDirectory()) }

    public static func defaultProjectRoots(home: String) -> [String] {
        let fm = FileManager.default
        let candidates = ["Developer", "Projects", "projects", "Code", "code", "src", "dev", "work", "repos", "git", "github",
                          "github.com", "gitlab.com", "Workspace", "workspace", "Sites"]
        var roots = candidates.map { home + "/" + $0 }.filter { fm.fileExists(atPath: $0) }
        // Also any "*.com" style folder layouts (~/github.com, ~/tk.com, …) people use for clones.
        if let top = try? fm.contentsOfDirectory(atPath: home) {
            roots += top.filter { $0.hasSuffix(".com") || $0.hasSuffix(".org") || $0.hasSuffix(".io") }
                .map { home + "/" + $0 }
        }
        let resolvedHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        var seen = Set<String>()
        let distinct = roots.filter {
            let resolved = URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
            return FS.isDirectory($0) && resolved != resolvedHome && seen.insert(resolved).inserted
        }
        let resolved = distinct.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        return distinct.enumerated().compactMap { index, root in
            resolved.indices.contains { $0 != index && resolved[index].hasPrefix(resolved[$0] + "/") } ? nil : root
        }
    }
}

// MARK: - Formatting

public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(bytes)
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        return i == 0 ? "\(bytes) B" : String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, units[i])
    }
}

/// Memory counters use powers of 1024; disk sizes keep ByteFormat's decimal units.
public enum MemoryFormat {
    public static func string(bytes: UInt64) -> String { format(Double(bytes)) }
    public static func string(kibibytes: Int) -> String { format(Double(max(0, kibibytes)) * 1024) }
    public static func string(mebibytes: Int) -> String { format(Double(max(0, mebibytes)) * 1_048_576) }

    public static func string(mebibytes: Double) -> String {
        guard mebibytes.isFinite else { return "—" }
        return format(mebibytes * 1_048_576)
    }

    private static func format(_ bytes: Double) -> String {
        guard bytes.isFinite else { return "—" }
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        let sign = bytes < 0 ? "-" : ""
        var value = abs(bytes)
        var index = 0
        while value >= 1024 && index < units.count - 1 { value /= 1024; index += 1 }
        return sign + String(format: index == 0 || value >= 100 ? "%.0f %@" : "%.1f %@", value, units[index])
    }
}

public enum AgeFormat {
    /// "5m ago", "3d ago", "2mo ago" (localized).
    public static func string(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        return tr("%1$@ ago", span(date, now: now))
    }

    /// "5m", "3d", "2mo": how long ago, without "ago".
    public static func span(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 3600 { return tr("%1$@m", String(max(1, Int(s / 60)))) }
        if s < 86400 { return tr("%1$@h", String(Int(s / 3600))) }
        let d = Int(s / 86400)
        if d < 60 { return tr("%1$@d", String(d)) }
        if d < 730 { return tr("%1$@mo", String(d / 30)) }
        return tr("%1$@y", String(d / 365))
    }
}

/// `tr` with English singular/plural; `%1$@` is the count, further arguments follow.
public func trCount(_ n: Int, _ one: String, _ many: String, _ args: String...) -> String {
    let key = n == 1 ? one : many
    let all = [String(n)] + args
    let format = tr(key)
    return String(format: format, locale: nil, arguments: all.map { $0 as NSString })
}

/// Parses "30", "30d", "2w", "6m", "1y" into days.
public func parseDays(_ s: String) -> Int? {
    let t = s.lowercased().trimmingCharacters(in: .whitespaces)
    guard let unit = t.last else { return nil }
    if unit.isNumber { return Int(t).flatMap { $0 >= 0 ? $0 : nil } }
    guard let n = Int(t.dropLast()), n >= 0 else { return nil }
    switch unit {
    case "d": return n
    case "w": return n * 7
    case "m": return n * 30
    case "y": return n * 365
    default: return nil
    }
}

/// The last finished scan, kept so `thermo clean run` can act on it without scanning everything
/// again (a full scan takes minutes on a busy disk). Removal still re-checks every path.
public enum ScanReportCache {
    private static let lock = NSLock()
    private static func directory(home: String) -> URL {
        url(home: home).deletingLastPathComponent().appendingPathComponent("clean-reports", isDirectory: true)
    }

    private static func scopedURL(_ report: ScanReport, home: String) -> URL {
        let scope: [String: Any] = [
            "categories": report.categories?.map(\.rawValue).sorted() as Any? ?? NSNull(),
            "age": report.olderThanDays as Any? ?? NSNull(),
            "language": report.language as Any? ?? NSNull(),
            "roots": report.projectRoots?.sorted() as Any? ?? NSNull(),
            "discover": report.discoverProjectRoots as Any? ?? NSNull()
        ]
        let data = (try? JSONSerialization.data(withJSONObject: scope, options: .sortedKeys)) ?? Data()
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return directory(home: home).appendingPathComponent(key + ".json")
    }

    public static func url(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/dev.thermo/clean-report.json")
    }

    public static func save(_ r: ScanReport, home: String = NSHomeDirectory()) {
        guard valid(r) else { return }
        lock.lock(); defer { lock.unlock() }
        let folder = directory(home: home)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(r) else { return }
        try? data.write(to: url(home: home), options: .atomic) // compatibility with older builds
        let scoped = scopedURL(r, home: home)
        if let previous = decode(scoped), previous.started > r.started { return }
        try? data.write(to: scoped, options: .atomic)
        // Bound disk use even when custom roots / languages / age limits vary frequently.
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let sorted = files.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for old in sorted.dropFirst(32) { try? FileManager.default.removeItem(at: old) }
    }

    /// Cleaning invalidates every scope, so older plans cannot reappear after removal.
    public static func invalidate(home: String = NSHomeDirectory()) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(home: home))
        try? FileManager.default.removeItem(at: directory(home: home))
    }

    private static func decode(_ url: URL) -> ScanReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(ScanReport.self, from: data)
    }

    private static func valid(_ report: ScanReport) -> Bool {
        guard !report.cancelled, report.duration.isFinite, report.duration >= 0 else { return false }
        var ids = Set<String>()
        var total: Int64 = 0
        for item in report.items {
            guard !item.id.isEmpty, ids.insert(item.id).inserted, item.bytes >= 0, item.files >= 0 else { return false }
            let sum = total.addingReportingOverflow(item.bytes)
            guard !sum.overflow else { return false }
            total = sum.partialValue
            if let parts = item.parts {
                var partIDs = Set<String>()
                var bytes: Int64 = 0
                for part in parts {
                    guard !part.id.isEmpty, partIDs.insert(part.id).inserted, part.bytes >= 0 else { return false }
                    let sum = bytes.addingReportingOverflow(part.bytes)
                    guard !sum.overflow else { return false }
                    bytes = sum.partialValue
                }
            }
        }
        return true
    }

    /// The newest complete report matching the caller's exact scope and freshness needs.
    /// Reports keep their own scan dates; a fresh category never renews an older category.
    public static func load(home: String = NSHomeDirectory(), maxAge: TimeInterval, now: Date = Date(),
                            matching: (ScanReport) -> Bool = { _ in true }) -> ScanReport? {
        lock.lock(); defer { lock.unlock() }
        let saved = (try? FileManager.default.contentsOfDirectory(at: directory(home: home), includingPropertiesForKeys: nil)) ?? []
        var best: ScanReport?
        // Decode one report at a time; session reports can contain thousands of selectable parts.
        for candidate in [url(home: home)] + saved.filter({ $0.pathExtension == "json" }) {
            guard let r = decode(candidate), valid(r), now >= r.started,
                  now.timeIntervalSince(r.started) < maxAge, matching(r) else { continue }
            if best == nil || r.started > best!.started { best = r }
        }
        return best
    }
}
