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
                guard glob else { return path == value || path.hasPrefix(value + "/") || value.hasPrefix(path + "/") }
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
            return Pattern(glob: glob, values: Array(Set([entry, resolved])))
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

    /// The file's text, or nil when there is no file. Anything else that is wrong throws.
    static func read(home: String) throws -> String? {
        let location = url(home: home).path
        let fd = open(location, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
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
        guard info.st_size <= maxBytes else { throw error(tr("whitelist is larger than %1$@ KB: %2$@", String(maxBytes / 1024), location)) }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw error(tr("whitelist is larger than %1$@ KB: %2$@", String(maxBytes / 1024), location)) }
        guard let text = String(data: data, encoding: .utf8) else { throw error(tr("whitelist is not UTF-8 text: %1$@", location)) }
        return text
    }

    /// Absent file → empty whitelist. Lines that are not acceptable are skipped and listed in `rejected`.
    public static func load(home: String = NSHomeDirectory()) throws -> Whitelist {
        let file = url(home: home).path
        guard let text = try read(home: home) else { return Whitelist(file: file) }
        var entries: [String] = [], rejected: [Rejected] = []
        for (index, raw) in lines(text).enumerated() {
            switch parse(raw, home: home) {
            case .none: continue
            case .entry(let entry): if !entries.contains(entry) { entries.append(entry) }
            case .rejected(let reason): rejected.append(Rejected(line: index + 1, text: raw, reason: reason))
            }
        }
        return Whitelist(file: file, entries: entries, rejected: rejected)
    }

    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
    }

    enum Line: Equatable { case none, entry(String), rejected(String) }

    static func parse(_ raw: String, home: String) -> Line {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { return .none }
        if line.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) { return .rejected("contains control characters") }
        let expanded = FS.expand(line, home: home)
        guard expanded.hasPrefix("/") else { return .rejected("not an absolute path") }
        let parts = expanded.split(separator: "/")
        if parts.contains("..") { return .rejected("contains ..") }
        let path = "/" + parts.filter { $0 != "." }.joined(separator: "/")
        let canonicalHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
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
        guard !patterns.isEmpty else { return false }
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        let candidates = Set([standard, Guard.deletionLocation(standard), URL(fileURLWithPath: standard).resolvingSymlinksInPath().path])
        return candidates.contains { c in patterns.contains { $0.matches(c) } }
    }

    /// The item with whitelisted paths taken out and listed in `whitelisted`; when every path is
    /// whitelisted it keeps its paths and is blocked instead.
    public func apply(_ item: CleanItem) -> CleanItem {
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
        do { return try (whitelist ?? load(home: home)).protects(path) ? tr(reason) : nil }
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

    /// Appends the paths not already listed; returns what was added. Comments and other lines stay.
    @discardableResult
    public static func add(_ paths: [String], home: String = NSHomeDirectory()) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let stored = try paths.map { try storedForm($0, home: home) }
        let text = try read(home: home) ?? "# Thermo cleanup whitelist: one absolute path or glob per line; ~/ is your home folder.\n"
        var lines = lines(text)
        if lines.last == "" { lines.removeLast() }
        var present = Set(lines.compactMap { if case .entry(let e) = parse($0, home: home) { return e }; return nil })
        var added: [String] = []
        for s in stored {
            let entry = FS.expand(s, home: home)
            guard present.insert(entry).inserted else { continue }
            lines.append(s); added.append(entry)
        }
        if !added.isEmpty { try write(lines, home: home) }
        record("whitelistAdd", added, home: home)
        return added
    }

    /// Removes lines naming these paths; returns what was removed. Comments and other lines stay.
    @discardableResult
    public static func remove(_ paths: [String], home: String = NSHomeDirectory()) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let wanted = Set(try paths.map { FS.expand(try storedForm($0, home: home), home: home) })
        guard let text = try read(home: home) else { return [] }
        var lines = lines(text)
        if lines.last == "" { lines.removeLast() }
        var removed: [String] = []
        lines.removeAll { line in
            guard case .entry(let e) = parse(line, home: home), wanted.contains(e) else { return false }
            if !removed.contains(e) { removed.append(e) }
            return true
        }
        if !removed.isEmpty { try write(lines, home: home) }
        record("whitelistRemove", removed, home: home)
        return removed
    }

    static func record(_ action: String, _ paths: [String], home: String) {
        guard !paths.isEmpty else { return }
        OperationJournal.record(OperationRecord(feature: "clean", action: action,
                                                items: paths.map { .init(target: $0, status: "done") }), home: home)
    }

    /// Temp file in the same folder, 0600, synced, then renamed over the old one.
    static func write(_ lines: [String], home: String) throws {
        let location = url(home: home)
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        guard data.count <= maxBytes else { throw error(tr("whitelist would be larger than %1$@ KB", String(maxBytes / 1024))) }
        let dir = location.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var template = Array((dir.path + "/.whitelist.XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw error(tr("whitelist could not be written")) }
        let temp = String(cString: template)
        var ok = false
        defer { if !ok { unlink(temp) } }
        do {
            defer { close(fd) }
            guard fchmod(fd, 0o600) == 0 else { throw error(tr("whitelist could not be written")) }
            try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
            guard fsync(fd) == 0 else { throw error(tr("whitelist could not be written")) }
        }
        guard rename(temp, location.path) == 0 else { throw error(tr("whitelist could not be written")) }
        ok = true
        ScanReportCache.invalidate(home: home)
    }
}

public extension ScanReport {
    /// Marks whitelisted paths; an unreadable whitelist blocks every item with paths (fail closed).
    mutating func applyWhitelist(home: String = NSHomeDirectory()) {
        do {
            items = try Whitelist.load(home: home).apply(items)
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
