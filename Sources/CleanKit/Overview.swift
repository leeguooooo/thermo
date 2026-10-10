import Foundation
import ThermoL10n

/// "Where did my disk go?": the volume's used space split into the places that hold it, each with
/// its biggest folders. Read-only; it explains, cleanup items act.
public struct SpaceOverview: Codable, Sendable {
    public struct Entry: Codable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var path: String?
        /// Space on disk (`du`), shared blocks included.
        public var bytes: Int64
        /// The biggest folders inside, biggest first.
        public var children: [Entry]
        public var note: String?
    }

    public var capacity: Int64
    public var free: Int64
    /// Purgeable space macOS frees on demand (local snapshots, iCloud copies, caches it manages).
    public var purgeable: Int64
    public var entries: [Entry]
    public var duration: TimeInterval
    public var cancelled: Bool? = nil
    public var measuredAt: Date? = nil
    public var language: String? = nil
    public var unreadable: [String]? = nil

    public var used: Int64 { capacity - free }

    struct Spot {
        let id: String
        let title: String
        let paths: [String]
        /// List this many of the biggest folders inside.
        let children: Int
        var note: String? = nil
    }

    /// Measures in parallel at background priority. `onProgress` gets each finished spot's title,
    /// `onEntry` the spot itself, so a UI can show results as they come in.
    public static func measure(home: String = NSHomeDirectory(), onProgress: ((String) -> Void)? = nil,
                               onEntry: ((Entry) -> Void)? = nil, cancellation: ScanCancellation = ScanCancellation()) -> SpaceOverview {
        let started = Date()
        let language = L10n.current.rawValue
        let url = URL(fileURLWithPath: home)
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                       .volumeAvailableCapacityForImportantUsageKey])
        let capacity = Int64(values?.volumeTotalCapacity ?? 0)
        let free = Int64(values?.volumeAvailableCapacity ?? 0)
        let important = values?.volumeAvailableCapacityForImportantUsage ?? Int64(free)

        let h = { (p: String) in home + "/" + p }
        let userTemp = (NSTemporaryDirectory() as NSString).deletingLastPathComponent  // /var/folders/xx/…/ (T's parent)
        // A bounded set of places known to grow big. Walking all of home takes many minutes on a full
        // disk; what is not measured here is reported as one remainder.
        let spots: [Spot] = [
            Spot(id: "apps", title: tr("Applications"), paths: ["/Applications", h("Applications")], children: 8),
            Spot(id: "app-data", title: tr("App data (Application Support, Containers)"),
                 paths: [h("Library/Application Support"), h("Library/Containers"), h("Library/Group Containers")], children: 10),
            Spot(id: "caches", title: tr("Caches"), paths: [h("Library/Caches")], children: 6),
            Spot(id: "developer", title: tr("Xcode and simulators"), paths: [h("Library/Developer")], children: 5),
            Spot(id: "trash", title: tr("Trash"), paths: [h(".Trash")], children: 0),
            // Not X: those are code-sign clones that share their blocks with the app (counted as ~0).
            Spot(id: "temp", title: tr("Temporary files"), paths: [userTemp + "/T", userTemp + "/C", "/private/tmp"], children: 6,
                 note: tr("the system clears most of this itself; agents and build tools leave the rest")),
            Spot(id: "homebrew", title: "Homebrew", paths: ["/opt/homebrew", "/usr/local"], children: 4),
        ]

        var unreadable: [String] = []
        var entries = [Entry?](repeating: nil, count: spots.count)
        let lock = NSLock()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        queue.qualityOfService = .background
        for (i, spot) in spots.enumerated() {
            queue.addOperation {
                guard !cancellation.isCancelled else { return }
                var denied: [String] = []
                let roots = spot.paths.filter { path in
                    if FS.exists(path) { return true }
                    if FS.size(path, cancellation: cancellation).denied { denied.append(path) }
                    return false
                }
                // Measure each folder one level down once; the spot's total is their sum.
                var kids: [Entry] = []
                var total: Int64 = 0
                for root in roots {
                    if cancellation.isCancelled { return }
                    let inner = spot.children > 0 && FS.isDirectory(root) && !isBundle(root) ? FS.children(root) : [root]
                    if inner.isEmpty, FS.size(root, cancellation: cancellation).denied { denied.append(root) }
                    for c in inner {
                        if cancellation.isCancelled { return }
                        let measured = FS.size(c, cancellation: cancellation)
                        if measured.denied { denied.append(c) }
                        let size = measured.allocated
                        total += size
                        if spot.children > 0 && size > 0 {
                            kids.append(Entry(id: c, title: FS.tilde(c, home: home), path: c, bytes: size, children: []))
                        }
                    }
                }
                guard !cancellation.isCancelled else { return }
                kids.sort { $0.bytes > $1.bytes }
                let e = Entry(id: spot.id, title: spot.title, path: roots.count == 1 ? roots[0] : nil, bytes: total,
                              children: Array(kids.prefix(spot.children)), note: spot.note)
                lock.lock(); entries[i] = e; unreadable.append(contentsOf: denied); lock.unlock()
                onEntry?(e)
                onProgress?(spot.title)
            }
        }
        // Simulator runtimes live on their own disk images: same disk, no folder to measure.
        var runtimes: Entry?
        queue.addOperation {
            guard !cancellation.isCancelled else { return }
            if let json = Shell.run("xcrun simctl runtime list -j 2>/dev/null", timeout: 30),
               let list = try? JSONDecoder().decode([String: Simulators.Runtime].self, from: Data(json.utf8)) {
                let kids = list.values.map { r in
                    Entry(id: "runtime/" + r.identifier, title: Simulators.runtimeName(r.runtimeIdentifier, version: r.version),
                          path: nil, bytes: r.sizeBytes ?? 0, children: [])
                }.sorted { $0.bytes > $1.bytes }
                guard !cancellation.isCancelled else { return }
                let total = kids.reduce(Int64(0)) { $0 + $1.bytes }
                if total > 0 {
                    lock.lock()
                    runtimes = Entry(id: "simulator-runtimes", title: tr("Simulator runtimes"), path: nil, bytes: total, children: kids,
                                     note: tr("separate disk images; remove unused ones with xcrun simctl runtime delete"))
                    lock.unlock()
                }
            }
            onProgress?(tr("Simulator runtimes"))
        }
        queue.waitUntilAllOperationsAreFinished()

        var list = entries.compactMap { $0 } + (cancellation.isCancelled ? [] : [runtimes, swap()].compactMap { $0 })
        let counted = list.reduce(Int64(0)) { $0 + $1.bytes }
        let used = capacity - free
        if !cancellation.isCancelled, used > counted {
            list.append(Entry(id: "other", title: tr("Your files, projects and tool folders, and macOS"), path: nil, bytes: used - counted,
                              children: [], note: tr("not measured one by one; thermo clean finds what in here can go")))
        }
        list.sort { $0.bytes > $1.bytes }
        var result = SpaceOverview(capacity: capacity, free: free, purgeable: max(0, important - free), entries: list,
                                   duration: Date().timeIntervalSince(started))
        result.cancelled = cancellation.isCancelled
        result.measuredAt = started
        result.language = language
        result.unreadable = Array(Set(unreadable)).sorted()
        return result
    }

    /// Swap files live in the same container: when memory runs short, they take disk space.
    static func swap() -> Entry? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0, usage.xsu_total > 0 else { return nil }
        return Entry(id: "swap", title: tr("Swap (memory moved to disk)"), path: "/System/Volumes/VM", bytes: Int64(usage.xsu_total),
                     children: [], note: tr("grows when memory runs short and shrinks after a restart; closing idle apps and agent sessions keeps it small"))
    }

    /// The last measurement, saved so the window opens with numbers instead of a 5-minute wait.
    public static var cacheURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/dev.thermo/space-overview.json")
    }

    public static func cached(from url: URL = cacheURL, now: Date = Date()) -> (SpaceOverview, Date)? {
        guard let data = try? Data(contentsOf: url),
              let overview = try? JSONDecoder().decode(SpaceOverview.self, from: data),
              overview.cancelled != true, overview.language == L10n.current.rawValue,
              let measuredAt = overview.measuredAt, measuredAt <= now,
              overview.capacity > 0, overview.free >= 0, overview.free <= overview.capacity,
              overview.purgeable >= 0, overview.duration.isFinite, overview.duration >= 0,
              validEntries(overview.entries) else { return nil }
        return (overview, measuredAt)
    }

    private static func validEntries(_ entries: [Entry]) -> Bool {
        var ids = Set<String>()
        return entries.allSatisfy { $0.bytes >= 0 && ids.insert($0.id).inserted && validEntries($0.children) }
    }

    public func save(to url: URL = Self.cacheURL) {
        guard cancelled != true else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    static func isBundle(_ path: String) -> Bool {
        ["app", "bundle", "framework", "photoslibrary", "musiclibrary", "tvlibrary"].contains((path as NSString).pathExtension.lowercased())
    }
}
