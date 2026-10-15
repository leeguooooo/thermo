import AgentCore
import Darwin
import Foundation

public struct TrashBatch: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var original: String
        public var destination: String
        public var identity: String
        public var bytes: Int64
        public var registrationBackup: String?
        public var birthIdentity: String? = nil
        public var registrationOriginal: String?
    }
    public var id: String
    public var created: Date
    public var entries: [Entry]
}

/// Records the actual Trash URLs returned by macOS. A manifest never authorizes a whole Trash.
public enum TrashBatches {
    private static let lock = NSLock()
    static func root(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Thermo/cleanup-batches")
    }
    static func url(_ id: String, home: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw NSError(domain: "Thermo", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid batch id"]) }
        return root(home: home).appendingPathComponent(id + ".jsonl")
    }
    struct JournalLine: Codable {
        var id: String?
        var created: Date?
        var entry: TrashBatch.Entry?
    }
    static func error(_ message: String) -> NSError {
        NSError(domain: "Thermo", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    public static func load(_ id: String, home: String = NSHomeDirectory()) throws -> TrashBatch {
        let location = try url(id, home: home)
        let fd = open(location.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw error("batch record could not be opened") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_size <= 8 * 1024 * 1024, flock(fd, LOCK_SH | LOCK_NB) == 0 else { throw error("batch record is unavailable or busy") }
        defer { flock(fd, LOCK_UN) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard data.last == 10 else { throw error("incomplete batch journal; no deletion is authorized") }
        let lines = data.split(separator: 10)
        guard let first = lines.first else { throw error("empty batch journal") }
        let header = try JSONDecoder().decode(JournalLine.self, from: Data(first))
        guard header.id == id, let created = header.created, header.entry == nil else { throw error("invalid batch header") }
        var entries: [String: TrashBatch.Entry] = [:]
        for line in lines.dropFirst() {
            let value = try JSONDecoder().decode(JournalLine.self, from: Data(line))
            guard value.id == nil, value.created == nil, let entry = value.entry else { throw error("invalid batch entry") }
            entries[entry.destination] = entry
        }
        return TrashBatch(id: id, created: created, entries: entries.values.sorted { $0.destination < $1.destination })
    }
    static func birthIdentity(_ path: String) -> String? {
        var value = stat()
        guard lstat(path, &value) == 0 else { return nil }
        return "\(value.st_birthtimespec.tv_sec):\(value.st_birthtimespec.tv_nsec):\(value.st_gen)"
    }
    static func append(_ original: TrashBatch.Entry, id: String, home: String) throws {
        var entry = original
        if entry.birthIdentity == nil { entry.birthIdentity = birthIdentity(entry.destination) }
        guard entry.birthIdentity != nil else { throw error("Trash item creation identity could not be captured") }
        lock.lock(); defer { lock.unlock() }
        let location = try url(id, home: home)
        try FileManager.default.createDirectory(at: root(home: home), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = open(location.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw error("batch journal could not be opened") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              info.st_size <= 8 * 1024 * 1024, flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw error("batch journal is unavailable or busy") }
        defer { flock(fd, LOCK_UN) }
        guard fstat(fd, &info) == 0 else { throw error("batch journal changed") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        if info.st_size == 0 {
            data.append(try encoder.encode(JournalLine(id: id, created: Date(), entry: nil))); data.append(10)
        }
        data.append(try encoder.encode(JournalLine(id: nil, created: nil, entry: entry))); data.append(10)
        guard info.st_size + Int64(data.count) <= 8 * 1024 * 1024 else { throw error("batch journal size limit reached") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: data)

    }
    static func synchronize(_ id: String, home: String) throws {
        let location = try url(id, home: home)
        let fd = open(location.path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else { throw error("batch journal could not be synchronized") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw error("batch journal is busy") }
        defer { flock(fd, LOCK_UN) }
        guard fsync(fd) == 0 else { throw error("batch journal could not be synchronized") }
    }

    /// Moves a hand-picked path to the Trash and records where macOS put it in batch `id`. The move
    /// throws; a failed recording comes back as the reason, with the item already in the Trash.
    static func trash(_ path: String, bytes: Int64, id: String, home: String,
                      move: (String) throws -> URL = RemovalOperations.live.trash) throws -> String? {
        let destination = try move(path)
        do {
            guard let identity = FileIdentity.of(destination.path) else { throw error("Trash destination identity could not be read") }
            try append(TrashBatch.Entry(original: path, destination: destination.path, identity: identity, bytes: bytes), id: id, home: home)
            return nil
        } catch { return "moved to " + destination.path + ", but batch recording failed: " + error.localizedDescription }
    }

    /// Flushes the batch a result recorded; a failure is reported, the items stay in the Trash.
    static func seal(_ result: inout CleanResult, home: String) {
        guard let batch = result.trashBatchID else { return }
        do { try synchronize(batch, home: home) } catch { result.failed["batch/" + batch] = error.localizedDescription }
    }

    /// The operation history entry for a hand-picked move to the Trash, undoable through its batch.
    static func journal(_ result: CleanResult, feature: String, action: String, subject: String?, sizes: [String: Int64], home: String) {
        let moved = result.removed.map { OperationRecord.Item(target: $0, bytes: sizes[$0], status: "done") }
        let failed = result.failed.sorted { $0.key < $1.key }.map { OperationRecord.Item(target: $0.key, status: "failed", detail: $0.value) }
        OperationJournal.record(OperationRecord(feature: feature, action: action, subject: subject, items: moved + failed,
                                                undo: result.trashBatchID.map { .init(kind: "trashBatch", ref: $0) }), home: home)
    }

    public static func refusal(_ entry: TrashBatch.Entry, home: String = NSHomeDirectory()) -> String? {
        let trash = home + "/.Trash"
        let path = entry.destination
        // Immediate children only, with the directory's identity and resolved ancestors rechecked.
        guard (path as NSString).deletingLastPathComponent == trash,
              URL(fileURLWithPath: trash).resolvingSymlinksInPath().path == trash,
              Guard.deletionLocation(path) == path else { return "batch target is outside the expected Trash" }
        guard FS.exists(path) else { return "item was restored or is missing" }
        guard FileIdentity.of(path) == entry.identity, let birth = entry.birthIdentity, birthIdentity(path) == birth else { return "Trash item was replaced" }
        var st = stat()
        guard lstat(path, &st) == 0, st.st_uid == getuid(), (st.st_mode & S_IFMT) != S_IFLNK else { return "Trash item ownership or type changed" }
        return nil
    }

    public static func empty(_ id: String, home: String = NSHomeDirectory()) throws -> CleanResult {
        let batch = try load(id, home: home)
        var result = CleanResult(id: "trash-batch/" + id, trashed: false)
        let before = DiskSpaceSnapshot.measure(path: home)
        for entry in batch.entries {
            if let reason = refusal(entry, home: home) { result.failed[entry.destination] = reason; continue }
            let size = FS.size(entry.destination)
            guard !size.denied else { result.failed[entry.destination] = "cannot measure Trash item"; continue }
            guard let files = OpenFiles.current() else { result.failed[entry.destination] = "cannot check open files"; continue }
            if let holder = files.holder(of: entry.destination) { result.failed[entry.destination] = "in use by " + holder.name; continue }
            if let reason = refusal(entry, home: home) { result.failed[entry.destination] = reason; continue }
            do {
                try FileManager.default.removeItem(atPath: entry.destination)
                result.removed.append(entry.destination); result.bytes += size.bytes
            } catch {
                Cleaner.accountPartialRemoval(entry.destination, before: size, identity: entry.identity, result: &result)
                result.failed[entry.destination] = error.localizedDescription
            }
        }
        result.outcome = result.failed.isEmpty ? "success" : (result.removed.isEmpty && result.partialRemoved?.isEmpty != false ? "failed" : "partial")
        result.spaceObservation = DiskSpaceObservation(before: before, after: DiskSpaceSnapshot.measure(path: home))
        let item = CleanItem(id: result.id, category: .system, title: "Trash batch", safety: .risky, paths: batch.entries.map(\.destination))
        Cleaner.log(result, item: item, to: Cleaner.logURL(home: home))
        return result
    }

    /// Puts a batch's items back where they were. Each one moves only when it is still the same
    /// Trash item, nothing is at its original path (new data there wins), and the original folder is
    /// still there on the same volume. A rename, never a copy; one bad entry never stops the rest.
    public static func restore(id: String, home: String = NSHomeDirectory(), dryRun: Bool = false) throws -> TrashRestore {
        let batch = try load(id, home: home)
        var result = TrashRestore(id: batch.id, dryRun: dryRun)
        for entry in batch.entries {
            var item = TrashRestore.Item(original: entry.original, destination: entry.destination, bytes: entry.bytes, status: "restored")
            if let (status, reason) = restoreRefusal(entry, home: home) {
                item.status = status; item.reason = reason
            } else if !dryRun {
                if renamex_np(entry.destination, entry.original, UInt32(RENAME_EXCL)) != 0 {
                    let code = errno
                    item.status = code == EEXIST ? "conflict" : "failed"
                    item.reason = code == EEXIST ? tr("something new is at the original path; it was kept") : String(cString: strerror(code))
                }
            }
            result.items.append(item)
        }
        guard !dryRun else { return result }
        if result.items.contains(where: { $0.status == "restored" }) {
            ScanReportCache.invalidate(home: home)
            SpaceOverview.invalidate(home: home)
        }
        OperationJournal.record(OperationRecord(feature: "history", action: "restore", subject: batch.id, items: result.items.map {
            .init(target: $0.original, bytes: $0.status == "restored" && $0.bytes > 0 ? $0.bytes : nil,
                  status: $0.status == "restored" ? "done" : $0.status == "skipped" ? "skipped" : "failed", detail: $0.reason)
        }), home: home)
        return result
    }

    /// Why an entry stays in the Trash, as (status, reason); nil when it can move back.
    static func restoreRefusal(_ entry: TrashBatch.Entry, home: String) -> (String, String)? {
        if entry.registrationBackup != nil { return ("skipped", tr("Git worktree with its registration; restore manually")) }
        guard FS.exists(entry.destination) else { return ("missing", tr("no longer in the Trash")) }
        if let why = refusal(entry, home: home) { return ("changed", why) }
        let original = entry.original
        guard original.hasPrefix("/"), !original.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            return ("skipped", tr("not a full path"))
        }
        var st = stat()
        // lstat: a dangling link at the original path is still something there.
        if lstat(original, &st) == 0 { return ("conflict", tr("something new is at the original path; it was kept")) }
        let parent = (original as NSString).deletingLastPathComponent
        var dir = stat(), item = stat()
        guard lstat(parent, &dir) == 0, (dir.st_mode & S_IFMT) == S_IFDIR,
              URL(fileURLWithPath: parent).resolvingSymlinksInPath().path == parent else {
            return ("skipped", tr("its original folder is gone or moved"))
        }
        // The user's own folders, or an app folder (root:admin) the user may write to.
        guard dir.st_uid == getuid() || (["/Applications", home + "/Applications"].contains(parent) && access(parent, W_OK) == 0) else {
            return ("skipped", tr("its original folder belongs to another user"))
        }
        guard lstat(entry.destination, &item) == 0, item.st_dev == dir.st_dev else { return ("skipped", tr("on another volume")) }
        return nil
    }
}

public struct TrashRestore: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public var original: String
        public var destination: String
        public var bytes: Int64
        /// restored (would be restored, in a dry run) | conflict | missing | changed | skipped | failed
        public var status: String
        public var reason: String? = nil
    }
    public var id: String
    public var dryRun: Bool
    public var items: [Item] = []
}
