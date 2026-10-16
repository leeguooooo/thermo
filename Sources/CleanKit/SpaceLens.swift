import CoreServices
import Darwin
import Foundation
import ThermoL10n

/// One file or folder in the space browser.
public struct SpaceEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var isDir: Bool
    /// Estimated private usage, counting hard links once; actual reclaimed space is measured separately.
    public var bytes: Int64
    public var files: Int
    /// Newest modification or status change inside.
    public var newest: Date?
    public var sizeState: AppSizeState? = nil
    public var effectiveSizeState: AppSizeState { sizeState ?? (bytes > 0 ? .incomplete : .unavailable) }
    public var sizeText: String { AppSize.text(bytes, state: effectiveSizeState) }
}

/// A folder's contents, biggest first. Items under the size floor are summed into `otherBytes`.
public struct SpaceFolder: Codable, Sendable {
    public var entry: SpaceEntry
    public var children: [SpaceEntry]
    public var otherBytes: Int64
    public var otherCount: Int
}

/// A big file, for the large and old files list.
public struct LargeFile: Codable, Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var path: String
    public var bytes: Int64
    public var modified: Date
}

/// The result of walking one folder tree once: every folder big enough to look into, and the big files.
public struct SpaceTree: Codable, Sendable {
    public var root: String
    public var scanned: Date
    public var folders: [String: SpaceFolder]
    public var large: [LargeFile]
    public var unreadable: [String]
    public var complete: Bool
    public var duration: TimeInterval
    public var language: String?
    public var sizeVersion: Int? = nil
    public var cancelled: Bool? = nil

    public func folder(_ path: String) -> SpaceFolder? { folders[path] }

    /// The folders from the root down to `path`, for the path bar.
    public func trail(to path: String) -> [SpaceEntry] {
        guard path == root || path.hasPrefix(root + "/") else { return [] }
        var out: [SpaceEntry] = []
        var p = path
        while true {
            if let f = folders[p] { out.append(f.entry) }
            if p == root || p == "/" { break }
            p = (p as NSString).deletingLastPathComponent
        }
        return out.reversed()
    }

    /// The tree after `paths` went to the Trash: they leave their folders, and the folders above
    /// them shrink by what they held. Nothing is measured again.
    public func removing(_ paths: Set<String>) -> SpaceTree {
        var t = self
        var selected: [String] = []
        for path in paths.sorted() where path == root || path.hasPrefix(root + "/") {
            if !selected.contains(where: { path.hasPrefix($0 + "/") }) { selected.append(path) }
        }
        var uncertain = Set<String>()
        for path in selected {
            let parent = (path as NSString).deletingLastPathComponent
            let held = folders[parent]?.children.first(where: { $0.path == path }) ?? folders[path]?.entry
            let knownBytes = held?.bytes ?? large.first(where: { $0.path == path })?.bytes
            let knownFiles = held?.files ?? (large.contains(where: { $0.path == path }) ? 1 : nil)
            for key in t.folders.keys where key == path || key.hasPrefix(path + "/") { t.folders[key] = nil }
            t.large.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
            for key in t.folders.keys where path.hasPrefix(key + "/") {
                guard var f = t.folders[key] else { continue }
                let represented = f.children.contains { $0.path == path || path.hasPrefix($0.path + "/") }
                f.children.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
                if let bytes = knownBytes, let count = knownFiles, folders[parent] != nil {
                    if let i = f.children.firstIndex(where: { path.hasPrefix($0.path + "/") }) {
                        f.children[i].bytes = max(0, f.children[i].bytes - bytes)
                        f.children[i].files = max(0, f.children[i].files - count)
                    }
                    if !represented {
                        f.otherBytes = max(0, f.otherBytes - bytes)
                        if key == parent { f.otherCount = max(0, f.otherCount - 1) }
                    }
                    f.entry.bytes = max(0, f.entry.bytes - bytes); f.entry.files = max(0, f.entry.files - count)
                } else { uncertain.insert(path) }
                f.children.sort { $0.bytes > $1.bytes }; t.folders[key] = f
            }
        }
        // An omitted entry with no retained estimate cannot be subtracted from
        // an aggregate. Rebuild affected ancestors from surviving known entries;
        // never label an old overestimate as a lower bound.
        if !uncertain.isEmpty {
            t.complete = false
            let beforeUnknown = t.folders
            for key in t.folders.keys.sorted(by: { $0.count > $1.count }) where uncertain.contains(where: { $0.hasPrefix(key + "/") }) {
                guard var f = t.folders[key] else { continue }
                let affected = uncertain.filter { $0.hasPrefix(key + "/") }
                // Omitted directory branches still have retained folder records.
                // Bring affected branches back as partial entries so their known
                // survivors are not lost with the parent's aggregate bucket.
                for (childPath, child) in t.folders where (childPath as NSString).deletingLastPathComponent == key &&
                    affected.contains(where: { $0.hasPrefix(childPath + "/") }) && !f.children.contains(where: { $0.path == childPath }) {
                    if let previous = beforeUnknown[childPath] {
                        f.otherBytes = max(0, f.otherBytes - previous.entry.bytes); f.otherCount = max(0, f.otherCount - 1)
                        f.children.append(child.entry)
                    }
                }
                let uncovered = affected.contains { removed in !f.children.contains { removed.hasPrefix($0.path + "/") } }
                for i in f.children.indices where affected.contains(where: { $0.hasPrefix(f.children[i].path + "/") }) {
                    if let child = t.folders[f.children[i].path] { f.children[i] = child.entry }
                    else { f.children[i].bytes = 0; f.children[i].files = 0; f.children[i].sizeState = .unavailable }
                }
                if uncovered { f.otherBytes = 0; f.otherCount = 0 }
                f.entry.bytes = f.children.reduce(f.otherBytes) { $0 + $1.bytes }
                f.entry.files = f.children.reduce(f.otherCount) { $0 + $1.files }
                f.entry.sizeState = f.entry.bytes > 0 ? .incomplete : .unavailable
                f.children.sort { $0.bytes > $1.bytes }
                t.folders[key] = f
            }
        }

        return t
    }
}

/// Walks a folder tree once with `getattrlistbulk` and keeps what a space browser needs: each
/// folder's biggest entries (DaisyDisk-style drill-down without walking again), and the big files.
public enum SpaceLens {
    /// Entries smaller than this are summed per folder; folders smaller than this are not kept.
    public static let floor: Int64 = 1 << 20
    public static let maxChildren = 300
    public static let largeFile: Int64 = 100 << 20

    public struct Progress: Sendable {
        public var files: Int
        public var bytes: Int64
        public var current: String
    }

    public static func scan(_ root: String, cancellation: ScanCancellation = ScanCancellation(),
                            progress: ((Progress) -> Void)? = nil) -> SpaceTree {
        let started = Date()
        let rootPath = (root as NSString).standardizingPath
        var st = stat()
        guard lstat(rootPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            return SpaceTree(root: rootPath, scanned: started, folders: [:], large: [], unreadable: [rootPath],
                             complete: false, duration: 0, language: L10n.current.rawValue, sizeVersion: 1, cancelled: cancellation.isCancelled)
        }
        let walker = Walker(root: rootPath, device: st.st_dev, cancellation: cancellation, progress: progress)
        walker.run()
        return SpaceTree(root: rootPath, scanned: started, folders: walker.folders,
                         large: walker.large.sorted { $0.bytes > $1.bytes }, unreadable: Set(walker.unreadable).sorted(),
                         complete: !cancellation.isCancelled && walker.folders[rootPath]?.entry.effectiveSizeState == .complete,
                         duration: Date().timeIntervalSince(started), language: L10n.current.rawValue,
                         sizeVersion: 1, cancelled: cancellation.isCancelled)
    }

    /// A fixed pool of threads takes folders off one shared stack, at every depth. Listing a
    /// folder is mostly waiting on the disk, so more threads than cores keep the SSD busy. A folder
    /// is finished, and handed up to its parent, when its last subfolder is.
    final class Walker: @unchecked Sendable {
        final class Node {
            let path: String
            let parent: Node?
            var pending = 0
            var kids: [SpaceEntry] = []
            var total: Int64 = 0
            var count = 0
            var newest = 0
            var other: Int64 = 0
            var otherCount = 0
            var ok = true
            var finished = false
            init(path: String, parent: Node?) { self.path = path; self.parent = parent }
        }

        let root: String
        let device: dev_t
        let cancellation: ScanCancellation
        let progress: ((Progress) -> Void)?
        let lock = NSLock()
        let queue = NSCondition()
        var stack: [Node] = []
        var nodes: [String: Node] = [:]
        var done = false
        var folders: [String: SpaceFolder] = [:]
        var large: [LargeFile] = []
        var unreadable: [String] = []
        var linksSeen = Set<UInt64>()
        var files = 0
        var bytes: Int64 = 0
        var lastReport = Date.distantPast
        static let threads = 16

        init(root: String, device: dev_t, cancellation: ScanCancellation, progress: ((Progress) -> Void)?) {
            self.root = root; self.device = device; self.cancellation = cancellation; self.progress = progress
        }

        func run() {
            stack = [Node(path: root, parent: nil)]
            nodes = [root: stack[0]]
            let group = DispatchGroup()
            for _ in 0..<Walker.threads {
                let t = Thread { [self] in work(); group.leave() }
                t.stackSize = 1 << 20
                group.enter()
                t.start()
            }
            group.wait()
            // Cancelled workers leave queued children unfinished. Fold each of those back into
            // its parent so known bytes remain browsable and unvisited folders stay unknown.
            if cancellation.isCancelled {
                for node in nodes.values.sorted(by: { $0.path.count > $1.path.count }) where !node.finished {
                    node.ok = false
                    finish(node)
                }
            }
        }

        private func work() {
            while true {
                queue.lock()
                while stack.isEmpty && !done && !cancellation.isCancelled { queue.wait(until: Date().addingTimeInterval(0.2)) }
                if done || cancellation.isCancelled { queue.unlock(); return }
                let node = stack.removeLast()
                queue.unlock()
                list(node)
            }
        }

        private func list(_ node: Node) {
            let dir = node.path
            var subdirs: [String] = []
            var fileEntries: [BulkWalk.Entry] = []
            var failures: [String] = []
            let listed = BulkWalk.entries(of: dir, cancellation: cancellation) { e in
                if e.error != 0 { failures.append(dir + "/" + e.name); return }
                if e.isDir { subdirs.append(dir + "/" + e.name) } else { fileEntries.append(e) }
            }
            node.ok = listed && failures.isEmpty && !cancellation.isCancelled
            var bigFiles: [LargeFile] = []
            var own: Int64 = 0
            for e in fileEntries {
                if cancellation.isCancelled { node.ok = false; break }
                let path = dir + "/" + e.name
                var size: Int64
                if e.links > 1 {
                    lock.lock(); let first = linksSeen.insert(e.fileID).inserted; lock.unlock()
                    size = first ? e.allocated : 0
                } else {
                    size = e.allocated >= BulkWalk.privateSizeThreshold ? (BulkWalk.fileSize(path)?.privateSize ?? e.allocated) : e.allocated
                }
                let changed = max(e.modified, e.changed)
                node.newest = max(node.newest, changed)
                own += size; node.count += 1
                if e.isFile, size >= SpaceLens.largeFile {
                    bigFiles.append(LargeFile(path: path, bytes: size, modified: Date(timeIntervalSince1970: TimeInterval(e.modified))))
                }
                if size >= SpaceLens.floor {
                    node.kids.append(SpaceEntry(path: path, name: e.name, isDir: false, bytes: size, files: 1,
                                                newest: Date(timeIntervalSince1970: TimeInterval(changed)), sizeState: .complete))
                } else { node.other += size; node.otherCount += 1 }
            }
            node.total = own
            // Stay on this volume: mounted images and network shares are not this disk's space.
            let local = subdirs.filter { path in
                var st = stat()
                guard lstat(path, &st) == 0 else { failures.append(path); node.ok = false; return false }
                return st.st_dev == device
            }

            lock.lock()
            large += bigFiles
            if !listed { unreadable.append(dir) }
            unreadable += failures
            files += node.count
            bytes += own
            let report = progress != nil && Date().timeIntervalSince(lastReport) > 0.25
            if report { lastReport = Date() }
            let snapshot = Progress(files: files, bytes: bytes, current: dir)
            node.pending = local.count
            lock.unlock()
            if report { progress?(snapshot) }

            if local.isEmpty { finish(node); return }
            queue.lock()
            let children = local.reversed().map { Node(path: $0, parent: node) }
            stack.append(contentsOf: children)
            // Register unfinished nodes before making them runnable; finished nodes are released.
            lock.lock(); for child in children { nodes[child.path] = child }; lock.unlock()
            queue.broadcast()
            queue.unlock()
        }

        /// Files the folder, then adds it to its parent, finishing that too when it was the last.
        private func finish(_ start: Node) {
            var node: Node? = start
            while let n = node {
                if n.finished { return }
                n.finished = true
                n.kids.sort { $0.bytes > $1.bytes }
                let known = n.kids.filter { $0.effectiveSizeState == .complete }
                if known.count > SpaceLens.maxChildren {
                    for k in known.dropFirst(SpaceLens.maxChildren) { n.other += k.bytes; n.otherCount += 1 }
                    n.kids = Array(known.prefix(SpaceLens.maxChildren)) + n.kids.filter { $0.effectiveSizeState != .complete }
                    n.kids.sort { $0.bytes > $1.bytes }
                }
                let entry = SpaceEntry(path: n.path, name: (n.path as NSString).lastPathComponent, isDir: true, bytes: n.total,
                                       files: n.count, newest: n.newest > 0 ? Date(timeIntervalSince1970: TimeInterval(n.newest)) : nil,
                                       sizeState: n.ok ? .complete : (n.total > 0 ? .incomplete : .unavailable))
                lock.lock()
                nodes[n.path] = nil
                if n.total >= SpaceLens.floor || !n.ok || n.parent == nil {
                    folders[n.path] = SpaceFolder(entry: entry, children: n.kids, otherBytes: n.other, otherCount: n.otherCount)
                }
                guard let p = n.parent else {
                    lock.unlock()
                    queue.lock(); done = true; queue.broadcast(); queue.unlock()
                    return
                }
                p.total += entry.bytes; p.count += entry.files
                p.ok = p.ok && n.ok
                if let d = entry.newest { p.newest = max(p.newest, Int(d.timeIntervalSince1970)) }
                if entry.bytes >= SpaceLens.floor || !n.ok { p.kids.append(entry) } else { p.other += entry.bytes; p.otherCount += 1 }
                p.pending -= 1
                let last = p.pending == 0
                lock.unlock()
                node = last ? p : nil
            }
        }
    }

    // MARK: Cache

    public static var cacheURL: URL {
        cacheURL(home: NSHomeDirectory())
    }
    public static func cacheURL(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/dev.thermo/space-lens.json")
    }
    @discardableResult public static func invalidateCache(at url: URL = cacheURL) -> Bool {
        guard directCacheLocation(url) else { return false }
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return errno == ENOENT }
        guard value.st_mode & S_IFMT == S_IFREG, value.st_uid == getuid(), value.st_nlink == 1 else { return false }
        return unlink(url.path) == 0
    }

    public static func cached(root: String, from url: URL = cacheURL) -> SpaceTree? {
        guard directCacheLocation(url) else { return nil }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var before = stat(), after = stat(), visible = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(), before.st_nlink == 1,
              before.st_size > 0, before.st_size <= 64 * 1024 * 1024,
              let data = try? handle.read(upToCount: 64 * 1024 * 1024 + 1), data.count == before.st_size,
              fstat(fd, &after) == 0, lstat(url.path, &visible) == 0,
              AppDataReviewIdentity.text(before) == AppDataReviewIdentity.text(after),
              visible.st_dev == before.st_dev, visible.st_ino == before.st_ino,
              let t = try? JSONDecoder().decode(SpaceTree.self, from: data),
              t.root == root, validCache(t), t.language == L10n.current.rawValue else { return nil }
        return t
    }

    public static func save(_ tree: SpaceTree, to url: URL = cacheURL) {
        guard validCache(tree), directCacheLocation(url) else { return }
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_uid == getuid(), existing.st_nlink == 1 else { return }
        } else if errno != ENOENT { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(tree), data.count <= 64 * 1024 * 1024 else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func directCacheLocation(_ url: URL) -> Bool {
        func systemSpelling(_ path: String) -> String {
            for root in ["/private/var", "/private/tmp", "/private/etc"] where path == root || path.hasPrefix(root + "/") {
                return String(path.dropFirst("/private".count))
            }
            return path
        }
        let plain = url.standardizedFileURL
        let location = plain.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(plain.lastPathComponent).path
        return systemSpelling(location) == systemSpelling(plain.path)
    }

    private static func validCache(_ tree: SpaceTree) -> Bool {
        tree.complete && tree.sizeVersion == 1 && tree.cancelled != true && tree.unreadable.isEmpty && tree.folders[tree.root] != nil &&
            tree.folders.allSatisfy { path, folder in
                path == folder.entry.path && folder.entry.effectiveSizeState == .complete && folder.entry.bytes >= 0 && folder.entry.files >= 0 &&
                    folder.otherBytes >= 0 && folder.otherCount >= 0 &&
                    folder.children.allSatisfy { $0.effectiveSizeState == .complete && $0.bytes >= 0 && $0.files >= 0 }
            }
    }

    // MARK: Last opened

    /// Unknown metadata cannot establish that a file has not been opened recently.
    public static func notOpened(since cutoff: Date, lastOpened: Date?) -> Bool {
        guard let lastOpened, lastOpened.timeIntervalSinceReferenceDate.isFinite else { return false }
        return lastOpened < cutoff
    }

    /// When Spotlight last saw the file opened, or nil when it does not know.
    public static func lastOpened(_ path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
