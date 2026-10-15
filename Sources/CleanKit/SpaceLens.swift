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
        for path in paths {
            // What the removed thing held, from its parent's listing.
            let parent = (path as NSString).deletingLastPathComponent
            guard let held = t.folders[parent]?.children.first(where: { $0.path == path }) else { continue }
            for key in t.folders.keys where key == path || key.hasPrefix(path + "/") { t.folders[key] = nil }
            t.large.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
            var p = parent
            while var f = t.folders[p] {
                f.children.removeAll { $0.path == path }
                if let i = f.children.firstIndex(where: { path.hasPrefix($0.path + "/") }) {
                    f.children[i].bytes = max(0, f.children[i].bytes - held.bytes)
                    f.children[i].files = max(0, f.children[i].files - held.files)
                }
                f.children.sort { $0.bytes > $1.bytes }
                f.entry.bytes = max(0, f.entry.bytes - held.bytes)
                f.entry.files = max(0, f.entry.files - held.files)
                t.folders[p] = f
                if p == t.root || p == "/" { break }
                p = (p as NSString).deletingLastPathComponent
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
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/dev.thermo/space-lens.json")
    }

    public static func cached(root: String, from url: URL = cacheURL) -> SpaceTree? {
        guard let data = try? Data(contentsOf: url), let t = try? JSONDecoder().decode(SpaceTree.self, from: data),
              t.root == root, validCache(t), t.language == L10n.current.rawValue else { return nil }
        return t
    }

    public static func save(_ tree: SpaceTree, to url: URL = cacheURL) {
        guard validCache(tree) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(tree).write(to: url, options: .atomic)
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

    /// When Spotlight last saw the file opened, or nil when it does not know.
    public static func lastOpened(_ path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
