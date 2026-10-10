// Processes, live agent sessions and the protected-path guard are shared with the agent doctor.
@_exported import AgentCore
// User-facing text goes through tr(); the CLI pins English, the app follows the chosen language.
@_exported import ThermoL10n
import Foundation

/// What a finding is, for grouping in the CLI and the app.
public enum CleanCategory: String, CaseIterable, Codable, Sendable {
    case aiSessions = "ai-sessions"
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
        case .aiModels: return tr("AI models")
        case .aiCaches: return tr("AI tool caches")
        case .devCaches: return tr("Developer caches")
        case .xcode: return "Xcode"
        case .projects: return tr("Project build artifacts")
        case .browsers: return tr("Browser caches")
        case .system: return tr("System & apps")
        }
    }

    public var isAI: Bool { [.aiSessions, .aiModels, .aiCaches].contains(self) }
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

    public init(id: String, category: CleanCategory, title: String, detail: String = "", safety: Safety,
                bytes: Int64 = 0, files: Int = 0, lastUsed: Date? = nil, paths: [String] = [],
                note: String? = nil, blocked: String? = nil, hint: String? = nil, afterClean: [String]? = nil) {
        self.id = id; self.category = category; self.title = title; self.detail = detail; self.safety = safety
        self.bytes = bytes; self.files = files; self.lastUsed = lastUsed; self.paths = paths
        self.note = note; self.blocked = blocked; self.hint = hint; self.afterClean = afterClean
    }

    public var cleanable: Bool { blocked == nil && !paths.isEmpty && bytes > 0 }
}

public struct ScanReport: Codable, Sendable {
    public var items: [CleanItem]
    /// Locations we could not read (usually needs Full Disk Access).
    public var denied: [String]
    public var started: Date
    public var duration: TimeInterval
    /// Claude Code `cleanupPeriodDays` (it prunes its own sessions after this many days; default 30).
    public var claudeCleanupDays: Int?

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
    public var categories: Set<CleanCategory> = Set(CleanCategory.allCases)
    public var home: String = NSHomeDirectory()

    public init() {}

    public static var defaultProjectRoots: [String] {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        let candidates = ["Developer", "Projects", "projects", "Code", "code", "src", "dev", "work", "repos", "git", "github",
                          "github.com", "gitlab.com", "Workspace", "workspace", "Sites"]
        var roots = candidates.map { home + "/" + $0 }.filter { fm.fileExists(atPath: $0) }
        // Also any "*.com" style folder layouts (~/github.com, ~/tk.com, …) people use for clones.
        if let top = try? fm.contentsOfDirectory(atPath: home) {
            roots += top.filter { $0.hasSuffix(".com") || $0.hasSuffix(".org") || $0.hasSuffix(".io") }
                .map { home + "/" + $0 }
        }
        var seen = Set<String>()
        return roots.filter { seen.insert(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path).inserted }
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
