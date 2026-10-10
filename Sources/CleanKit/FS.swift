import Darwin
import Foundation

/// Size of a file tree: symlinks are not followed, it stays on one volume, hard links count once.
public struct TreeSize: Sendable {
    /// What removing it would free: each file's private (unshared) blocks. On APFS, clones and
    /// snapshot-shared data make this smaller — sometimes far smaller — than `allocated`.
    public var bytes: Int64 = 0
    /// Space the files take up as `du` counts it, shared blocks included.
    public var allocated: Int64 = 0
    public var files: Int = 0
    public var newest: Date?
    public var denied = false

    public static func + (a: TreeSize, b: TreeSize) -> TreeSize {
        var r = a
        r.bytes += b.bytes; r.allocated += b.allocated; r.files += b.files; r.denied = a.denied || b.denied
        if let n = b.newest, n > (r.newest ?? .distantPast) { r.newest = n }
        return r
    }
}

public enum FS {
    static let fm = FileManager.default

    public static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    public static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    public static func mtime(_ path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    /// Directory entries with their type from `readdir` (no stat per entry). Symlinks are never directories.
    public static func entries(_ path: String) -> [(name: String, isDir: Bool)]? {
        guard let d = opendir(path) else { return nil }
        defer { closedir(d) }
        var out: [(String, Bool)] = []
        while let e = readdir(d) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(e.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            out.append((name, e.pointee.d_type == DT_DIR))
        }
        return out
    }

    public static func children(_ path: String) -> [String] {
        (try? fm.contentsOfDirectory(atPath: path))?.map { path + "/" + $0 } ?? []
    }

    /// Sizes a path. `trackNewest` stats modification times too (slightly slower).
    /// Stops early (partial size) when the running scan is cancelled.
    public static func size(_ path: String, trackNewest: Bool = false) -> TreeSize {
        var r = TreeSize()
        var st = stat()
        guard lstat(path, &st) == 0 else {
            if errno == EACCES || errno == EPERM { r.denied = true }
            return r
        }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            let blocks = Int64(st.st_blocks) * 512
            let sizes = (st.st_mode & S_IFMT) == S_IFREG ? BulkWalk.fileSize(path) : nil
            r.allocated = sizes?.allocated ?? blocks
            r.bytes = sizes?.privateSize ?? blocks
            r.files = 1
            r.newest = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            return r
        }
        // Batched attributes with private sizes; fts below is the fallback for file systems
        // without getattrlistbulk.
        if let bulk = BulkWalk.size(path, trackNewest: trackNewest, device: st.st_dev) { return bulk }
        var seenInodes = Set<UInt64>()
        let opts = FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV
        var newest: Int = 0
        path.withCString { cpath in
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(cpath), nil]
            defer { free(argv[0]) }
            guard let fts = fts_open(&argv, opts, nil) else { return }
            defer { fts_close(fts) }
            var visited = 0
            while let ent = fts_read(fts) {
                visited += 1
                if visited & 0x3FF == 0, ScanCancellation.current?.isCancelled == true { break }
                let info = Int32(ent.pointee.fts_info)
                switch info {
                case FTS_DNR, FTS_ERR, FTS_NS:
                    if ent.pointee.fts_errno == EACCES || ent.pointee.fts_errno == EPERM { r.denied = true }
                case FTS_DP:
                    continue
                default:
                    guard let sp = ent.pointee.fts_statp else { continue }
                    let s = sp.pointee
                    if (s.st_mode & S_IFMT) != S_IFDIR {
                        if s.st_nlink > 1 && !seenInodes.insert(UInt64(s.st_ino)).inserted { continue }
                        r.files += 1
                    }
                    r.bytes += Int64(s.st_blocks) * 512
                    r.allocated += Int64(s.st_blocks) * 512
                    if trackNewest, s.st_mtimespec.tv_sec > newest { newest = s.st_mtimespec.tv_sec }
                }
            }
        }
        if trackNewest, newest > 0 { r.newest = Date(timeIntervalSince1970: TimeInterval(newest)) }
        return r
    }

    public static func size(_ paths: [String], trackNewest: Bool = false) -> TreeSize {
        paths.reduce(TreeSize()) { $0 + size($1, trackNewest: trackNewest) }
    }

    /// Reads up to `limit` bytes from the start of a file.
    public static func head(_ path: String, limit: Int = 64 * 1024) -> Data? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        return try? h.read(upToCount: limit)
    }

    public static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst() : path
    }

    /// `/Users/leo/x` → `~/x` for display.
    public static func tilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Removal

public struct CleanResult: Codable, Sendable {
    public var id: String
    public var removed: [String] = []
    public var failed: [String: String] = [:]
    public var bytes: Int64 = 0
    public var trashed: Bool
}

public enum RemovalMode: String, Sendable {
    /// Caches go away for good, user data goes to the Trash.
    case auto
    case trash
    case permanent

    public func trashes(_ safety: Safety) -> Bool {
        switch self {
        case .auto: return safety != .safe
        case .trash: return true
        case .permanent: return false
        }
    }
}

public enum Cleaner {
    public static var logURL: URL { logURL(home: NSHomeDirectory()) }

    static func logURL(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Logs/Thermo/clean.log")
    }

    /// Removes the item's paths. Every path is re-checked against `Guard`; nothing outside
    /// `item.paths` is touched.
    /// `scannedAt`: paths modified after this moment changed since the user saw the scan and are skipped.
    public static func clean(_ item: CleanItem, mode: RemovalMode = .auto, guard g: Guard = Guard(),
                             scannedAt: Date? = nil) -> CleanResult {
        let trash = mode.trashes(item.safety)
        var result = CleanResult(id: item.id, trashed: trash)
        guard item.blocked == nil else {
            result.failed[item.id] = item.blocked
            return result
        }
        let fm = FileManager.default
        for path in item.paths {
            if let why = g.refusal(path) { result.failed[path] = why; continue }
            guard FS.exists(path) else { continue }
            let size = FS.size(path, trackNewest: scannedAt != nil)
            if let t = scannedAt, let n = size.newest, n > t.addingTimeInterval(1) {
                result.failed[path] = "modified since the scan"
                continue
            }
            // Items already in the Trash can only be removed for good.
            let inTrash = path.hasPrefix(g.home + "/.Trash/")
            do {
                if trash && !inTrash {
                    try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                } else {
                    try fm.removeItem(atPath: path)
                }
                result.removed.append(path)
                result.bytes += size.bytes
            } catch {
                result.failed[path] = (error as NSError).localizedDescription
            }
        }
        if !result.removed.isEmpty, let cmds = item.afterClean {
            for c in cmds { _ = Shell.run(c, timeout: 30) }
        }
        log(result, item: item, to: logURL(home: g.home))
        return result
    }

    static func log(_ r: CleanResult, item: CleanItem, to url: URL) {
        let f = ISO8601DateFormatter()
        var lines = r.removed.map { "\(f.string(from: Date())) \(r.trashed ? "trash" : "delete") \(item.id) \($0)" }
        lines += r.failed.map { "\(f.string(from: Date())) failed \(item.id) \($0.key): \($0.value)" }
        guard !lines.isEmpty else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Shell

enum Shell {
    /// Runs `/bin/sh -c command`, returns stdout (nil on failure or timeout).
    @discardableResult
    static func run(_ command: String, timeout: TimeInterval = 10) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        let reader = DispatchQueue(label: "dev.thermo.clean.shell")
        let done = DispatchSemaphore(value: 0)
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
        done.wait()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}


/// Lets a running scan be stopped. `current` is the scan in progress in this process
/// (one at a time); the deep size walks check it every 1024 entries.
public final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private static let currentLock = NSLock()
    nonisolated(unsafe) private static var _current: ScanCancellation?
    public static var current: ScanCancellation? {
        get { currentLock.lock(); defer { currentLock.unlock() }; return _current }
        set { currentLock.lock(); _current = newValue; currentLock.unlock() }
    }
}
