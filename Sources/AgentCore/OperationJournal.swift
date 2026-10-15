import Darwin
import Foundation

/// One thing Thermo changed on disk or in the system: a cleanup, an uninstall, an agent fix, a
/// Claude reset, a browser setting … Structured, so the CLI and the app render it in the user's
/// language, and so each entry can point at the place that undoes it.
public struct OperationRecord: Codable, Sendable, Identifiable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        /// A path, or for non-file actions a name ("ANTHROPIC_API_KEY", "Google Chrome").
        public var target: String
        /// nil when the size is unknown, never 0 for "did not measure".
        public var bytes: Int64?
        /// done | partial | failed | skipped
        public var status: String
        public var detail: String?
        public init(target: String, bytes: Int64? = nil, status: String, detail: String? = nil) {
            self.target = target; self.bytes = bytes; self.status = status; self.detail = detail
        }
    }

    /// Where the change can be undone. Only `trashBatch` is undone from the history itself;
    /// the others name the store the owning feature restores from.
    public struct Undo: Codable, Sendable, Equatable {
        /// trashBatch | claudeReset | browserBackup | timezoneBackup | tabBatch | tabArchive |
        /// agentBackup | worktreeBackup | archiveManifest | trash
        public var kind: String
        public var ref: String
        public init(kind: String, ref: String) { self.kind = kind; self.ref = ref }
    }

    public var id: String
    public var time: Date
    /// clean | apps | space | agents | claudeReset | privacy | tabs | worktrees | archive | pulse | history
    public var feature: String
    /// trash | delete | uninstall | remove | restore | fix | apply | quit | restart | archive | organize | …
    public var action: String
    /// Rule, category, app or action identifier the entry is about.
    public var subject: String?
    /// succeeded | partial | failed
    public var outcome: String
    public var items: [Item]
    /// Sum of known item sizes; nil when any size is unknown and none is known.
    public var bytes: Int64?
    public var bytesIncomplete: Bool?
    public var undo: Undo?

    public init(id: String = UUID().uuidString, time: Date = Date(), feature: String, action: String, subject: String? = nil,
                outcome: String? = nil, items: [Item], undo: Undo? = nil) {
        self.id = id; self.time = time; self.feature = feature; self.action = action; self.subject = subject
        self.items = items; self.undo = undo
        let known = items.compactMap(\.bytes)
        self.bytes = known.isEmpty ? nil : known.reduce(0, +)
        self.bytesIncomplete = items.contains { $0.bytes == nil && $0.status != "failed" && $0.status != "skipped" } ? true : nil
        if let outcome { self.outcome = outcome } else {
            let failed = items.filter { $0.status == "failed" }.count
            let done = items.filter { $0.status == "done" || $0.status == "partial" }.count
            self.outcome = failed == 0 && !items.contains { $0.status == "partial" } ? "succeeded" : done == 0 ? "failed" : "partial"
        }
    }
}

/// Append-only history of every change Thermo makes, kept beside the batch and backup stores it
/// points at. Writing never fails or blocks the operation it records; reading skips damaged lines.
public enum OperationJournal {
    public static let maxBytes = 4 * 1024 * 1024
    /// Rotated generations kept besides the live file (operations.1.jsonl, operations.2.jsonl).
    public static let generations = 2
    private static let lock = NSLock()

    public static func url(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Thermo/operations.jsonl")
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e
    }
    static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    /// Records an operation. Errors are swallowed on purpose: the change already happened (or was
    /// refused) and the journal is a record of it, not a gate.
    public static func record(_ record: OperationRecord, home: String = NSHomeDirectory()) {
        guard !record.items.isEmpty || record.outcome == "failed" else { return }
        guard var line = try? encoder().encode(record) else { return }
        line.append(10)
        lock.lock(); defer { lock.unlock() }
        let location = url(home: home)
        let directory = location.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        rotateIfNeeded(location, adding: line.count)
        let fd = open(location.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { return }
        guard flock(fd, LOCK_EX) == 0 else { return }
        defer { flock(fd, LOCK_UN) }
        line.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { if errno == EINTR { continue }; return }
                offset += n
            }
        }
    }

    static func rotateIfNeeded(_ location: URL, adding: Int) {
        var info = stat()
        guard lstat(location.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) + adding > maxBytes else { return }
        let fm = FileManager.default
        func generation(_ n: Int) -> URL {
            location.deletingLastPathComponent().appendingPathComponent("operations.\(n).jsonl")
        }
        try? fm.removeItem(at: generation(generations))
        for n in stride(from: generations - 1, through: 1, by: -1) where fm.fileExists(atPath: generation(n).path) {
            try? fm.moveItem(at: generation(n), to: generation(n + 1))
        }
        try? fm.moveItem(at: location, to: generation(1))
    }

    /// Newest first, across the live file and its rotated generations. Damaged lines are skipped,
    /// never fatal: one torn write must not hide the rest of the history.
    public static func read(home: String = NSHomeDirectory(), limit: Int? = nil) -> [OperationRecord] {
        let location = url(home: home)
        let files = [location] + (1...generations).map {
            location.deletingLastPathComponent().appendingPathComponent("operations.\($0).jsonl")
        }
        var records: [OperationRecord] = []
        for file in files {
            guard let data = safeRead(file) else { continue }
            for line in data.split(separator: 10) {
                if let record = try? decoder().decode(OperationRecord.self, from: Data(line)) { records.append(record) }
            }
        }
        var seen = Set<String>()
        records = records.filter { seen.insert($0.id).inserted }.sorted { $0.time > $1.time }
        if let limit { return Array(records.prefix(max(0, limit))) }
        return records
    }

    public static func find(_ id: String, home: String = NSHomeDirectory()) -> OperationRecord? {
        read(home: home).first { $0.id == id || ($0.id.hasPrefix(id) && id.count >= 8) }
    }

    static func safeRead(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= off_t(maxBytes * 2) else { return nil }
        return try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd()
    }
}
