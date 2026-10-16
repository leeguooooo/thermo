import AgentCore
import Darwin
import Foundation

/// Paths the user always keeps: `~/Library/Application Support/Thermo/whitelist`, one absolute path
/// or glob per line (`~/` allowed, `#` comments). It only ever adds protection on top of `Guard`.
/// A file that is present but cannot be trusted throws, and destructive callers stop (fail closed).
public struct Whitelist: Sendable {
    public struct Rejected: Codable, Sendable, Equatable {
        public var line: Int
        public var text: String
        public var reason: String
    }

    /// Stable machine reason for skipped paths, also the `tr` key for the human one.
    public static let reason = "whitelisted"
    public static let maxBytes = 256 * 1024

    public let file: String
    /// Accepted entries, expanded to absolute paths or globs.
    public let entries: [String]
    public let rejected: [Rejected]
    let patterns: [Pattern]

    struct Pattern: Sendable {
        let glob: Bool
        /// The entry as written and, for plain paths, with symlinks resolved.
        let values: [String]

        func matches(_ path: String) -> Bool {
            if path == "/" { return true }
            return values.contains { value in
                // Also literally: a real name like `film [1].mkv` is not meant as a character class.
                if path == value || path.hasPrefix(value + "/") || value.hasPrefix(path + "/") { return true }
                guard glob else { return false }
                let have = path.split(separator: "/").map(String.init)
                let want = value.split(separator: "/").map(String.init)
                // A glob matches a whole number of components: inside a match, or a folder that may hold one.
                let n = min(have.count, want.count)
                let candidate = "/" + have.prefix(n).joined(separator: "/")
                let pattern = have.count >= want.count ? value : "/" + want.prefix(n).joined(separator: "/")
                return fnmatch(pattern, candidate, FNM_PATHNAME) == 0
            }
        }
    }

    public init(file: String, entries: [String] = [], rejected: [Rejected] = []) {
        self.file = file; self.entries = entries; self.rejected = rejected
        patterns = entries.map { entry in
            let glob = Self.isGlob(entry)
            let resolved = glob ? entry : URL(fileURLWithPath: entry).resolvingSymlinksInPath().path
            return Pattern(glob: glob, values: Array(Set([FS.systemSpelling(entry), FS.systemSpelling(resolved)])))
        }
    }

    public static func url(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Thermo/whitelist")
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "Thermo", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func isGlob(_ s: String) -> Bool { s.contains { "*?[".contains($0) } }

    // MARK: - Reading

    static func checkedLocation(home: String) throws -> URL {
        let location = url(home: home).path
        func systemSpelling(_ value: String) -> String {
            for root in ["/private/var", "/private/tmp", "/private/etc"] where value == root || value.hasPrefix(root + "/") {
                return String(value.dropFirst("/private".count))
            }
            return value
        }
        let plain = url(home: home).standardizedFileURL
        let resolved = plain.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(plain.lastPathComponent)
        guard systemSpelling(plain.path) == systemSpelling(resolved.path) else { throw error(tr("whitelist folder contains a symbolic link: %1$@", location)) }
        return plain
    }

    /// The file's text, or nil when there is no file. Anything else that is wrong throws.
    static func read(home: String, afterRead: () throws -> Void = {}) throws -> String? {
        let location = try checkedLocation(home: home).path
        let fd = open(location, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw error(tr("whitelist is a symbolic link: %1$@", location)) }
            throw error(tr("whitelist could not be opened: %1$@ (%2$@)", location, String(cString: strerror(errno))))
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw error(tr("whitelist could not be inspected: %1$@", location)) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw error(tr("whitelist is not a regular file: %1$@", location)) }
        guard info.st_uid == getuid() else { throw error(tr("whitelist is not owned by you: %1$@", location)) }
        guard info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { throw error(tr("whitelist is writable by other users: %1$@", location)) }
        guard info.st_nlink == 1 else { throw error(tr("whitelist has other hard links: %1$@", location)) }
        guard info.st_size >= 0, info.st_size <= maxBytes else { throw error(tr("whitelist is larger than %1$@ KB: %2$@", String(maxBytes / 1024), location)) }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw error(tr("whitelist is larger than %1$@ KB: %2$@", String(maxBytes / 1024), location)) }
        try afterRead()
        var after = stat(), visible = stat()
        guard data.count == info.st_size, fstat(fd, &after) == 0, lstat(location, &visible) == 0,
              after.st_nlink == 1, visible.st_nlink == 1,
              AppDataReviewIdentity.text(info) == AppDataReviewIdentity.text(after),
              AppDataReviewIdentity.text(after) == AppDataReviewIdentity.text(visible) else {
            throw error(tr("whitelist changed during reading; try again: %1$@", location))
        }
        guard var text = String(data: data, encoding: .utf8) else { throw error(tr("whitelist is not UTF-8 text: %1$@", location)) }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    /// Effective protection, ignoring comments/order while retaining resolved alias targets.
    var protectionKey: [String] {
        patterns.map { ($0.glob ? "glob:" : "path:") + $0.values.sorted().joined(separator: "\u{0}") }.sorted()
    }

    public var removalIssue: String? {
        guard !rejected.isEmpty else { return nil }
        return tr("whitelist has invalid entries at lines %1$@; fix them before cleanup", rejected.prefix(8).map { String($0.line) }.joined(separator: ", "))
    }

    /// Inspection can retain rejected rows, while every removal entry point requires a valid list.
    public static func loadForRemoval(home: String = NSHomeDirectory()) throws -> Whitelist {
        let value = try load(home: home)
        if let issue = value.removalIssue { throw error(issue) }
        return value
    }

    /// Inspection: absent file is empty; invalid lines are retained in `rejected`.
    /// Destructive callers must use loadForRemoval or validate removalIssue.
    public static func load(home: String = NSHomeDirectory()) throws -> Whitelist {
        inspect(try read(home: home), home: home)
    }

    static func inspect(_ text: String?, home: String) -> Whitelist {
        let file = url(home: home).path
        guard let text else { return Whitelist(file: file) }
        let canonicalHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        var entries: [String] = [], rejected: [Rejected] = []
        for (index, raw) in lines(text).enumerated() {
            switch parse(raw, home: home, canonicalHome: canonicalHome) {
            case .none: continue
            case .entry(let entry): if !entries.contains(entry) { entries.append(entry) }
            case .rejected(let reason): rejected.append(Rejected(line: index + 1, text: raw, reason: reason))
            }
        }
        return Whitelist(file: file, entries: entries, rejected: rejected)
    }

    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
    }

    enum Line: Equatable { case none, entry(String), rejected(String) }

    static func parse(_ raw: String, home: String, canonicalHome: String? = nil) -> Line {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { return .none }
        if line.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) { return .rejected("contains control characters") }
        let expanded = FS.expand(line, home: home)
        guard expanded.hasPrefix("/") else { return .rejected("not an absolute path") }
        let parts = expanded.split(separator: "/")
        if parts.contains("..") { return .rejected("contains ..") }
        let path = "/" + parts.filter { $0 != "." }.joined(separator: "/")
        let canonicalHome = canonicalHome ?? URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        let roots = ["/", home, canonicalHome, "/Users", "/System", "/Library", "/Applications", "/private", "/var", "/Volumes"]
        if roots.contains(path) { return .rejected("a system root or your home folder") }
        if isGlob(path) {
            let all = path.split(separator: "/").map(String.init)
            let fixed = all.prefix { !isGlob($0) }
            // `/*`, `/U*`, `~/*`: everything in a root.
            if fixed.isEmpty || (roots.contains("/" + fixed.joined(separator: "/")) && all.count == fixed.count + 1 && ["*", "**"].contains(all.last ?? "")) {
                return .rejected("matches everything in a system root or your home folder")
            }
        }
        return .entry(path)
    }

    // MARK: - Matching

    /// Whether removing `path` would remove something whitelisted: the path itself, anything under a
    /// whitelisted folder, or a folder holding a whitelisted path. Symlinked parents are checked both ways.
    public func protects(_ path: String) -> Bool {
        if removalIssue != nil { return true }
        guard !patterns.isEmpty else { return false }
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        let candidates = Set([standard, Guard.deletionLocation(standard), URL(fileURLWithPath: standard).resolvingSymlinksInPath().path])
        return candidates.contains { c in patterns.contains { $0.matches(FS.systemSpelling(c)) } }
    }

    /// The item with whitelisted paths taken out and listed in `whitelisted`; when every path is
    /// whitelisted it keeps its paths and is blocked instead.
    public func apply(_ item: CleanItem) -> CleanItem {
        if let issue = removalIssue {
            var blocked = item
            if !item.paths.isEmpty || !(item.commands ?? []).isEmpty { blocked.blocked = issue }
            return blocked
        }
        if Simulators.isItem(item), let issue = Simulators.reviewRefusal(item) { var blocked = item; blocked.blocked = issue; return blocked }
        if !(item.commands ?? []).isEmpty, ManagedToolScope.ids.contains(item.id), item.commandScope?.isEmpty != false {
            var blocked = item; blocked.blocked = tr(ManagedToolScope.unavailable); return blocked
        }
        if !(item.commands ?? []).isEmpty, let scope = item.commandScope {
            let protected = scope.filter(protects)
            if !protected.isEmpty {
                var blocked = item; blocked.blocked = tr("Tool cleanup overlaps a whitelisted location; keep it protected or review the whitelist first.")
                blocked.whitelisted = Array(Set((item.whitelisted ?? []) + protected)).sorted()
                return blocked
            }
        }
        let hits = item.paths.filter(protects)
        guard !hits.isEmpty else { return item }
        var i = item
        i.whitelisted = Array(Set((item.whitelisted ?? []) + hits)).sorted()
        let hit = Set(hits)
        let kept = item.paths.filter { !hit.contains($0) }
        if kept.isEmpty {
            i.blocked = i.blocked ?? tr(Self.reason)
            return i
        }
        if let parts = item.parts {
            i.parts = parts.compactMap { part in
                var p = part
                p.paths = part.paths.filter { !hit.contains($0) }
                if p.paths.count < part.paths.count { p.bytes = part.bytes * Int64(p.paths.count) / Int64(part.paths.count) }
                return p.paths.isEmpty ? nil : p
            }
            i.bytes = (i.parts ?? []).reduce(0) { $0 + $1.bytes }
        } else {
            i.bytes = item.bytes * Int64(kept.count) / Int64(item.paths.count)
        }
        i.paths = kept
        return i
    }

    public func apply(_ items: [CleanItem]) -> [CleanItem] { items.map(apply) }

    /// What a destructive caller shows when the whitelist cannot be read.
    public static func unreadable(_ error: Error) -> String {
        tr("the cleanup whitelist could not be read: %1$@", error.localizedDescription)
    }

    /// Why `path` must stay, or nil. An unreadable whitelist refuses everything.
    public static func refusal(_ path: String, home: String = NSHomeDirectory(), whitelist: Whitelist? = nil) -> String? {
        do {
            let value = try whitelist ?? loadForRemoval(home: home)
            if let issue = value.removalIssue { return issue }
            return value.protects(path) ? tr(reason) : nil
        }
        catch { return unreadable(error) }
    }

    // MARK: - Writing

    private static let lock = NSLock()

    /// Normalizes what the user typed into the form stored in the file (`~/` for the home folder).
    static func storedForm(_ input: String, home: String) throws -> String {
        switch parse(input, home: home) {
        case .entry(let path): return FS.tilde(path, home: home)
        case .rejected(let reason): throw error(tr("%1$@: %2$@", input, tr(reason)))
        case .none: throw error(tr("%1$@: %2$@", input, tr("not an absolute path")))
        }
    }

    public struct ProtectionReview: Sendable {
        public let value: Whitelist
        fileprivate let home: String
        fileprivate let identity: String?
        fileprivate let text: String?
    }

    /// Read-only review, including invalid rows; opening the manager creates no files.
    public static func review(home: String = NSHomeDirectory()) throws -> ProtectionReview {
        try review(home: home, afterRead: {})
    }

    static func review(home: String, afterRead: () throws -> Void) throws -> ProtectionReview {
        let file = try checkedLocation(home: home).path
        let before = AppDataReviewIdentity.of(file)
        let text = try read(home: home)
        try afterRead()
        guard AppDataReviewIdentity.of(file) == before else {
            throw error(tr("Protection list changed. Refresh it before changing a rule."))
        }
        return ProtectionReview(value: inspect(text, home: home), home: home, identity: before, text: text)
    }

    @discardableResult
    public static func removeReviewed(_ entry: String, review: ProtectionReview) throws -> [String] {
        guard review.value.entries.contains(entry) else { throw error(tr("This protection was not part of the reviewed list.")) }
        if let issue = review.value.removalIssue { throw error(issue) }
        lock.lock(); defer { lock.unlock() }
        let removed = try WhitelistWriteTransaction.run(home: review.home) { transaction in
            let snapshot = try transaction.snapshot()
            guard snapshot.identity == review.identity, snapshot.text == review.text, let text = snapshot.text else {
                throw error(tr("Protection list changed. Refresh it before changing a rule."))
            }
            var lines = lines(text)
            if lines.last == "" { lines.removeLast() }
            lines.removeAll { if case .entry(let value) = parse($0, home: review.home) { return value == entry }; return false }
            try transaction.write(lines, expected: snapshot.identity, beforeCommit: {})
            return [entry]
        }
        ScanReportCache.invalidate(home: review.home)
        record("whitelistRemove", removed, home: review.home)
        return removed
    }

    /// One local, exact-version undo for entries newly added by this operation.
    public struct AdditionUndo: Sendable {
        fileprivate let home: String
        fileprivate let paths: [String]
        fileprivate let identity: String
        fileprivate let text: String
    }

    public static func addWithUndo(_ paths: [String], home: String = NSHomeDirectory()) throws -> (added: [String], undo: AdditionUndo?) {
        try addChange(paths, home: home, reviewable: true, beforeCommit: {})
    }

    @discardableResult
    public static func undoAddition(_ undo: AdditionUndo) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let removed = try WhitelistWriteTransaction.run(home: undo.home) { transaction in
            let snapshot = try transaction.snapshot()
            guard snapshot.identity == undo.identity, snapshot.text == undo.text else {
                throw error(tr("Whitelist changed after protection was added. Review it before removing protection."))
            }
            var lines = lines(undo.text)
            if lines.last == "" { lines.removeLast() }
            let wanted = Set(undo.paths)
            lines.removeAll { line in
                if case .entry(let entry) = parse(line, home: undo.home) { return wanted.contains(entry) }
                return false
            }
            try transaction.write(lines, expected: snapshot.identity, beforeCommit: {})
            return undo.paths
        }
        ScanReportCache.invalidate(home: undo.home)
        record("whitelistRemove", removed, home: undo.home)
        return removed
    }

    /// Appends the paths not already listed; returns what was added. Comments and other lines stay.
    @discardableResult
    public static func add(_ paths: [String], home: String = NSHomeDirectory()) throws -> [String] {
        try add(paths, home: home, beforeCommit: {})
    }

    static func add(_ paths: [String], home: String, beforeCommit: () throws -> Void) throws -> [String] {
        try addChange(paths, home: home, reviewable: false, beforeCommit: beforeCommit).added
    }

    private static func addChange(_ paths: [String], home: String, reviewable: Bool,
                                  beforeCommit: () throws -> Void) throws -> (added: [String], undo: AdditionUndo?) {
        lock.lock(); defer { lock.unlock() }
        let stored = try paths.map { try storedForm($0, home: home) }
        let change = try WhitelistWriteTransaction.run(home: home) { transaction -> (added: [String], undo: AdditionUndo?) in
            let snapshot = try transaction.snapshot()
            let text = snapshot.text ?? "# Thermo cleanup whitelist: one absolute path or glob per line; ~/ is your home folder.\n"
            var lines = lines(text)
            if lines.last == "" { lines.removeLast() }
            var present = Set(lines.compactMap { if case .entry(let entry) = parse($0, home: home) { return entry }; return nil })
            var added: [String] = []
            for stored in stored {
                let entry = FS.expand(stored, home: home)
                guard present.insert(entry).inserted else { continue }
                lines.append(stored); added.append(entry)
            }
            var committedIdentity: String?
            if !added.isEmpty { committedIdentity = try transaction.write(lines, expected: snapshot.identity, beforeCommit: beforeCommit) }
            var undo: AdditionUndo?
            if reviewable, !added.isEmpty {
                let committed = try transaction.snapshot()
                guard let identity = committed.identity, identity == committedIdentity,
                      let text = committed.text, text == lines.joined(separator: "\n") + "\n" else { throw error(tr("whitelist changed during editing; review it and try again")) }
                undo = AdditionUndo(home: home, paths: added, identity: identity, text: text)
            }
            return (added, undo)
        }
        if !change.added.isEmpty { ScanReportCache.invalidate(home: home) }
        record("whitelistAdd", change.added, home: home)
        return change
    }

    /// Removes lines naming these paths; returns what was removed. Comments and other lines stay.
    @discardableResult
    public static func remove(_ paths: [String], home: String = NSHomeDirectory()) throws -> [String] {
        try remove(paths, home: home, beforeCommit: {})
    }

    static func remove(_ paths: [String], home: String, beforeCommit: () throws -> Void) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let wanted = Set(try paths.map { FS.expand(try storedForm($0, home: home), home: home) })
        let removed = try WhitelistWriteTransaction.run(home: home) { transaction -> [String] in
            let snapshot = try transaction.snapshot()
            guard let text = snapshot.text else { return [] }
            var lines = lines(text)
            if lines.last == "" { lines.removeLast() }
            var removed: [String] = []
            lines.removeAll { line in
                guard case .entry(let entry) = parse(line, home: home), wanted.contains(entry) else { return false }
                if !removed.contains(entry) { removed.append(entry) }; return true
            }
            if !removed.isEmpty { try transaction.write(lines, expected: snapshot.identity, beforeCommit: beforeCommit) }
            return removed
        }
        if !removed.isEmpty { ScanReportCache.invalidate(home: home) }
        record("whitelistRemove", removed, home: home)
        return removed
    }

    static func record(_ action: String, _ paths: [String], home: String) {
        guard !paths.isEmpty else { return }
        OperationJournal.record(OperationRecord(feature: "clean", action: action,
                                                items: paths.map { .init(target: $0, status: "done") }), home: home)
    }


}

public extension ScanReport {
    /// Marks whitelisted paths; an unreadable whitelist blocks every item with paths (fail closed).
    mutating func applyWhitelist(home: String = NSHomeDirectory()) {
        do {
            items = try Whitelist.loadForRemoval(home: home).apply(items)
            whitelistError = nil
        } catch {
            let why = Whitelist.unreadable(error)
            whitelistError = why
            items = items.map { item in
                var i = item
                if !i.paths.isEmpty || !(i.commands ?? []).isEmpty { i.blocked = why }
                return i
            }
        }
    }
}
