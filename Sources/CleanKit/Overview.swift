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
        /// False means bytes are a lower bound from fully measured children, not a final total.
        public var complete: Bool? = nil
        public var measuredLocations: Int? = nil
        public var totalLocations: Int? = nil
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

    struct MeasurementState {
        let spot: Spot
        let roots: [String]
        let paths: [String]
        var planned = true
        var done = 0
        var bytes: Int64 = 0
        var kids: [Entry] = []
        var denied: [String] = []
        var lastEmission: UInt64 = 0

        func entry() -> Entry {
            Entry(id: spot.id, title: spot.title, path: roots.count == 1 ? roots[0] : nil,
                  bytes: bytes, children: kids, note: spot.note, complete: planned && done == paths.count,
                  measuredLocations: done, totalLocations: paths.count)
        }
    }

    /// Measures in parallel; the app uses lowPriority to keep background disk I/O quiet. `onProgress` gets each finished spot's title,
    /// `onEntry` the spot itself, so a UI can show results as they come in.
    public static func measure(home: String = NSHomeDirectory(), onProgress: ((String) -> Void)? = nil,
                               onEntry: ((Entry) -> Void)? = nil, cancellation: ScanCancellation = ScanCancellation(), lowPriority: Bool = false) -> SpaceOverview {
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

        return measure(home: home, spots: spots, includeRuntimes: true, onProgress: onProgress,
                       onEntry: onEntry, cancellation: cancellation, lowPriority: lowPriority)
    }

    /// Internal planner entry point lets tests exercise scheduling with a disposable tree.
    static func measure(home: String, spots: [Spot], includeRuntimes: Bool = false,
                        onProgress: ((String) -> Void)? = nil, onEntry: ((Entry) -> Void)? = nil,
                        cancellation: ScanCancellation = ScanCancellation(), lowPriority: Bool = false,
                        footprint: @escaping (String, ScanCancellation) -> DiskFootprint = { FS.footprint($0, cancellation: $1) }) -> SpaceOverview {
        let started = Date()
        let language = L10n.current.rawValue
        let url = URL(fileURLWithPath: home)
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                       .volumeAvailableCapacityForImportantUsageKey])
        let capacity = Int64(values?.volumeTotalCapacity ?? 0)
        let free = Int64(values?.volumeAvailableCapacity ?? 0)
        let important = values?.volumeAvailableCapacityForImportantUsage ?? Int64(free)

        // Discover only immediate children up front. All categories share one bounded queue;
        // a huge application folder must not hold smaller siblings behind a serial category walk.
        var states = spots.map { spot -> MeasurementState in
            var roots: [String] = []
            var paths: [String] = []
            var denied: [String] = []
            for root in spot.paths {
                guard !cancellation.isCancelled else { break }
                guard FS.exists(root) else {
                    if FS.footprint(root, cancellation: cancellation).denied { denied.append(root) }
                    continue
                }
                roots.append(root)
                let children = spot.children > 0 && FS.isDirectory(root) && !isBundle(root) ? FS.children(root).sorted() : []
                paths += children.isEmpty ? [root] : children
            }
            return MeasurementState(spot: spot, roots: roots, paths: paths, planned: !cancellation.isCancelled, denied: denied)
        }
        let plannedPaths = states.map(\.paths)
        let lock = NSLock()
        let emissions = DispatchQueue(label: "dev.thermo.overview.results")
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        queue.qualityOfService = lowPriority ? .background : .utility
        let timing = ProcessInfo.processInfo.environment["THERMO_CLEAN_TIMING"] != nil
        // Simulator runtimes live on their own disk images: same disk, no folder to measure.
        var runtimes: Entry?
        if includeRuntimes { queue.addOperation {
            guard !cancellation.isCancelled else { return }
            let (status, json) = Shell.exec(["xcrun", "simctl", "runtime", "list", "-j"], timeout: 30, cancellation: cancellation)
            if status == 0, let list = try? JSONDecoder().decode([String: Simulators.Runtime].self, from: Data(json.utf8)) {
                let kids = list.values.map { r in
                    Entry(id: "runtime/" + r.identifier, title: Simulators.runtimeName(r.runtimeIdentifier, version: r.version),
                          path: nil, bytes: r.sizeBytes ?? 0, children: [])
                }.sorted { $0.bytes > $1.bytes }
                guard !cancellation.isCancelled else { return }
                let total = kids.reduce(Int64(0)) { $0 + $1.bytes }
                if total > 0 {
                    let e = Entry(id: "simulator-runtimes", title: tr("Simulator runtimes"), path: nil, bytes: total, children: kids,
                                  note: tr("separate disk images; remove unused ones with xcrun simctl runtime delete"))
                    lock.lock(); runtimes = e; lock.unlock()
                    onEntry?(e)
                }
            }
            onProgress?(tr("Simulator runtimes"))
        } }
        let order = spots.indices.sorted { priority(spots[$0].id) < priority(spots[$1].id) }
        for i in order where states[i].planned && plannedPaths[i].isEmpty {
            let entry = states[i].entry()
            emissions.async { onEntry?(entry); onProgress?(entry.title) }
        }
        // Four workers pull jobs rather than allocating an operation for every temp file.
        // This bounds queued memory and lets cancellation stop without draining thousands of jobs.
        let rounds = plannedPaths.map { $0.count }.max() ?? 0
        var nextRound = 0
        var nextColumn = 0
        func nextJob() -> (Int, String)? {
            lock.lock(); defer { lock.unlock() }
            while nextRound < rounds {
                let round = nextRound
                let index = order[nextColumn]
                nextColumn += 1
                if nextColumn == order.count { nextColumn = 0; nextRound += 1 }
                if round < plannedPaths[index].count { return (index, plannedPaths[index][round]) }
            }
            return nil
        }
        for _ in 0..<queue.maxConcurrentOperationCount {
            queue.addOperation {
                while !cancellation.isCancelled, let (i, path) = nextJob() {
                    guard !cancellation.isCancelled else { return }
                    let began = Date()
                    let measured = footprint(path, cancellation)
                    guard !cancellation.isCancelled else { return }
                    if timing, Date().timeIntervalSince(began) >= 1 {
                        FileHandle.standardError.write(Data(String(format: "overview: %.2fs %@, %d files\n", Date().timeIntervalSince(began), path, measured.files).utf8))
                    }
                    lock.lock()
                    states[i].done += 1
                    states[i].bytes += measured.allocated
                    if measured.denied { states[i].denied.append(path) }
                    if states[i].spot.children > 0, measured.allocated > 0 {
                        states[i].kids.append(Entry(id: path, title: FS.tilde(path, home: home), path: path,
                                                   bytes: measured.allocated, children: []))
                        states[i].kids.sort { $0.bytes > $1.bytes }
                        states[i].kids = Array(states[i].kids.prefix(states[i].spot.children))
                    }
                    let now = DispatchTime.now().uptimeNanoseconds
                    let complete = states[i].done == plannedPaths[i].count
                    if states[i].lastEmission == 0 || complete || now - states[i].lastEmission >= 250_000_000 {
                        states[i].lastEmission = now
                        let entry = states[i].entry()
                        // Serialized delivery prevents an older partial update following completion.
                        emissions.async {
                            onEntry?(entry)
                            if entry.complete == true { onProgress?(entry.title) }
                        }
                    }
                    lock.unlock()
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        emissions.sync {}

        let unreadable = states.flatMap(\.denied)
        var list = states.filter { $0.done > 0 || ($0.planned && $0.paths.isEmpty) }.map { $0.entry() } + [runtimes].compactMap { $0 } + (cancellation.isCancelled ? [] : [swap()].compactMap { $0 })
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

    private static func priority(_ id: String) -> Int {
        switch id {
        case "trash": return 0
        case "temp": return 1
        case "homebrew": return 2
        case "caches": return 3
        case "developer": return 4
        case "apps": return 5
        default: return 6
        }
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

    public static func invalidate(home: String = NSHomeDirectory(), now: Date = Date()) {
        let url = URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/dev.thermo/space-overview.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(String(now.timeIntervalSince1970).utf8).write(to: url.appendingPathExtension("invalidated"), options: .atomic)
        try? FileManager.default.removeItem(at: url)
    }

    /// Also protects against a measurement started before cleanup in another process.
    public static func isCurrent(measuredAt: Date?, cacheURL url: URL = cacheURL) -> Bool {
        guard let measuredAt else { return false }
        let marker = url.appendingPathExtension("invalidated")
        guard let data = try? Data(contentsOf: marker) else { return true }
        guard let seconds = Double(String(decoding: data, as: UTF8.self)), seconds.isFinite else { return false }
        return measuredAt.timeIntervalSince1970 >= seconds
    }

    public static func cached(from url: URL = cacheURL, now: Date = Date()) -> (SpaceOverview, Date)? {
        guard let data = try? Data(contentsOf: url),
              let overview = try? JSONDecoder().decode(SpaceOverview.self, from: data),
              overview.cancelled != true, overview.language == L10n.current.rawValue,
              let measuredAt = overview.measuredAt, measuredAt <= now, isCurrent(measuredAt: measuredAt, cacheURL: url),
              overview.capacity > 0, overview.free >= 0, overview.free <= overview.capacity,
              overview.purgeable >= 0, overview.duration.isFinite, overview.duration >= 0,
              validEntries(overview.entries) else { return nil }
        return (overview, measuredAt)
    }

    private static func validEntries(_ entries: [Entry]) -> Bool {
        var ids = Set<String>()
        return entries.allSatisfy { $0.complete != false && $0.bytes >= 0 && ids.insert($0.id).inserted && validEntries($0.children) }
    }

    public func save(to url: URL = Self.cacheURL) {
        guard cancelled != true, Self.validEntries(entries), Self.isCurrent(measuredAt: measuredAt, cacheURL: url) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    static func isBundle(_ path: String) -> Bool {
        ["app", "bundle", "framework", "photoslibrary", "musiclibrary", "tvlibrary"].contains((path as NSString).pathExtension.lowercased())
    }
}
