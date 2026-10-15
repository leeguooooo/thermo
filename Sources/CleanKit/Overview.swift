import Foundation
import Darwin
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
        /// What can be done about it: a command, a setting, or that macOS owns it.
        public var action: String? = nil
        public var attemptedLocations: Int? = nil
        public var sizeState: AppSizeState? = nil
        public var effectiveSizeState: AppSizeState { sizeState ?? (complete == false ? (bytes > 0 ? .incomplete : .unavailable) : .complete) }
        public var sizeText: String { AppSize.text(bytes, state: effectiveSizeState) }
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
    /// The headings add up to more than the disk uses by this much: hard links (pnpm stores and
    /// node_modules), APFS clones and files written while measuring count in each place.
    public var overcounted: Int64? = nil
    public var incompleteLocations: [String]? = nil
    public var sizeVersion: Int? = nil

    public var used: Int64 { capacity - free }

    struct Spot {
        let id: String
        let title: String
        let paths: [String]
        /// List this many of the biggest folders inside.
        let children: Int
        var note: String? = nil
        /// False: `paths` already are the folders to measure and list (a computed set, such as
        /// "every folder in home nothing else claims"); true: measure each path's children.
        var expand = true
        var action: String? = nil
        /// System folders only root can read are expected; they land in "not attributed" rather
        /// than asking for Full Disk Access, which would not open them either.
        var reportsDenied = true
    }

    struct MeasurementState {
        let spot: Spot
        let roots: [String]
        let paths: [String]
        var planned = true
        var done = 0
        var attempted = 0
        var incomplete: [String] = []
        var bytes: Int64 = 0
        var kids: [Entry] = []
        var denied: [String] = []
        var lastEmission: UInt64 = 0

        func entry() -> Entry {
            let complete = planned && attempted == paths.count && incomplete.isEmpty
            return Entry(id: spot.id, title: spot.title, path: roots.count == 1 ? roots[0] : nil,
                  bytes: bytes, children: kids, note: spot.note, complete: complete,
                  measuredLocations: done, totalLocations: paths.count, action: spot.action, attemptedLocations: attempted,
                  sizeState: complete ? .complete : bytes > 0 ? .incomplete : attempted > 0 || !incomplete.isEmpty ? .unavailable : .unmeasured)
        }
    }

    static let measurementConcurrency = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    private static let measurementQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = measurementConcurrency
        queue.qualityOfService = .background
        return queue
    }()

    /// Measures in parallel; the app uses lowPriority to keep background disk I/O quiet. `onProgress` gets each finished spot's title,
    /// `onEntry` the spot itself, so a UI can show results as they come in.
    public static func measure(home: String = NSHomeDirectory(), onProgress: ((String) -> Void)? = nil,
                               onEntry: ((Entry) -> Void)? = nil, cancellation: ScanCancellation = ScanCancellation(), lowPriority: Bool = false) -> SpaceOverview {
        let userTemp = (NSTemporaryDirectory() as NSString).deletingLastPathComponent  // /var/folders/xx/…/ (T's parent)
        let spots = Self.spots(home: home, dataRoot: FS.isDirectory(dataVolumeRoot) ? dataVolumeRoot : "/", userTemp: userTemp,
                               projectRoots: Self.projectRoots(home: home))
        return measure(home: home, spots: spots, includeRuntimes: true, includeVolumes: true, onProgress: onProgress,
                       onEntry: onEntry, cancellation: cancellation, lowPriority: lowPriority)
    }

    /// Internal planner entry point lets tests exercise scheduling with a disposable tree.
    static func measure(home: String, spots: [Spot], includeRuntimes: Bool = false, includeVolumes: Bool = false,
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
            var incomplete: [String] = []
            for root in spot.paths {
                guard !cancellation.isCancelled else { break }
                var info = stat()
                guard lstat(root, &info) == 0 else {
                    if errno != ENOENT {
                        incomplete.append(root)
                        if spot.reportsDenied && Self.ownedByMe(root) { denied.append(root) }
                    }
                    continue
                }
                roots.append(root)
                let children = spot.expand && spot.children > 0 && FS.isDirectory(root) && !isBundle(root) ? FS.children(root).sorted() : []
                paths += children.isEmpty ? [root] : children
            }
            return MeasurementState(spot: spot, roots: roots, paths: paths, planned: !cancellation.isCancelled, incomplete: incomplete, denied: denied)
        }
        let plannedPaths = states.map(\.paths)
        let lock = NSLock()
        let emissions = DispatchQueue(label: "dev.thermo.overview.results")
        let group = DispatchGroup()
        func enqueue(_ work: @escaping () -> Void) {
            group.enter()
            let operation = BlockOperation { defer { group.leave() }; work() }
            operation.qualityOfService = lowPriority ? .background : .utility
            measurementQueue.addOperation(operation)
        }
        let timing = ProcessInfo.processInfo.environment["THERMO_CLEAN_TIMING"] != nil
        // Simulator runtimes live on their own disk images: same disk, no folder to measure.
        var runtimes: Entry?
        if includeRuntimes { enqueue {
            guard !cancellation.isCancelled else { return }
            let (status, json) = Shell.exec(["xcrun", "simctl", "runtime", "list", "-j"], timeout: 30, cancellation: cancellation)
            guard !cancellation.isCancelled else { return }
            let e = status == 0 ? Self.runtimeEntry(Data(json.utf8)) : nil
            let entry = e ?? Entry(id: "simulator-runtimes", title: tr("Simulator runtimes"), bytes: 0, children: [],
                                   note: tr("Simulator runtime sizes could not be checked."), complete: false, sizeState: .unavailable)
            lock.lock(); runtimes = entry; lock.unlock()
            onEntry?(entry)
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
        for _ in 0..<measurementConcurrency {
            enqueue {
                while !cancellation.isCancelled, let (i, path) = nextJob() {
                    guard !cancellation.isCancelled else { return }
                    let began = Date()
                    let measured = footprint(path, cancellation)
                    guard !cancellation.isCancelled else { return }
                    if timing, Date().timeIntervalSince(began) >= 1 {
                        FileHandle.standardError.write(Data(String(format: "overview: %.2fs %@, %d files\n", Date().timeIntervalSince(began), path, measured.files).utf8))
                    }
                    lock.lock()
                    states[i].attempted += 1
                    let complete = !measured.denied && !measured.incomplete
                    if complete { states[i].done += 1 } else { states[i].incomplete.append(path) }
                    states[i].bytes += measured.allocated
                    // Only what the user owns can be opened by granting Full Disk Access; another
                    // user's or root's folder (/tmp/RustDesk-service) is expected to stay closed.
                    if measured.denied && states[i].spot.reportsDenied && Self.ownedByMe(path) { states[i].denied.append(path) }
                    if states[i].spot.children > 0, measured.allocated > 0 || !complete {
                        states[i].kids.append(Entry(id: path, title: Self.displayTitle(path, home: home), path: path,
                                                   bytes: measured.allocated, children: [], complete: complete, action: Self.assetAction(path),
                                                   sizeState: complete ? .complete : measured.allocated > 0 ? .incomplete : .unavailable))
                        states[i].kids.sort { $0.bytes > $1.bytes }
                        let known = states[i].kids.filter { $0.effectiveSizeState == .complete }
                        states[i].kids = Array(known.prefix(states[i].spot.children)) + states[i].kids.filter { $0.effectiveSizeState != .complete }
                        states[i].kids.sort { $0.bytes > $1.bytes }
                    }
                    let now = DispatchTime.now().uptimeNanoseconds
                    let finished = states[i].attempted == plannedPaths[i].count
                    if states[i].lastEmission == 0 || finished || now - states[i].lastEmission >= 250_000_000 {
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
        group.wait()
        emissions.sync {}

        let unreadable = states.flatMap(\.denied)
        let volumes = includeVolumes && !cancellation.isCancelled ? Self.containerVolumes(home: home) : nil
        var list = states.filter { $0.attempted > 0 || !$0.incomplete.isEmpty || ($0.planned && $0.paths.isEmpty) }.map { $0.entry() } + [runtimes].compactMap { $0 }
        if !cancellation.isCancelled {
            list += volumes.map { Self.volumeEntries($0) } ?? [swap()].compactMap { $0 }
        }
        let counted = list.reduce(Int64(0)) { $0 + $1.bytes }
        let used = capacity - free
        if !cancellation.isCancelled, used > counted {
            let snapshots = includeVolumes ? Self.localSnapshots() : 0
            let note = snapshots > 0
                ? tr("%1$@ local snapshots, APFS metadata and folders only macOS can read; Time Machine snapshots go away on their own as space is needed", String(snapshots))
                : tr("APFS metadata and folders only macOS can read (Spotlight index, file versions); not measured one by one")
            let complete = list.allSatisfy { $0.effectiveSizeState == .complete }
            list.append(Entry(id: "other", title: tr("Not attributed to a folder"), path: nil, bytes: used - counted,
                              children: [], note: complete ? note : tr("Includes unmeasured locations; this residual is not a measured folder size."),
                              complete: complete, sizeState: complete ? .complete : .unavailable))
        }
        list.sort { $0.bytes > $1.bytes }
        var result = SpaceOverview(capacity: capacity, free: free, purgeable: max(0, important - free), entries: list,
                                   duration: Date().timeIntervalSince(started))
        result.cancelled = cancellation.isCancelled
        result.measuredAt = started
        result.language = language
        result.unreadable = Array(Set(unreadable)).sorted()
        result.incompleteLocations = Array(Set(states.flatMap(\.incomplete))).sorted()
        result.sizeVersion = 1
        if !cancellation.isCancelled, counted > used + 1_000_000_000 { result.overcounted = counted - used }
        return result
    }

    static func runtimeEntry(_ data: Data) -> Entry? {
        guard let list = try? JSONDecoder().decode([String: Simulators.Runtime].self, from: data),
              list.values.allSatisfy({ ($0.sizeBytes ?? 0) >= 0 }) else { return nil }
        let kids = list.values.map { runtime in
            Entry(id: "runtime/" + runtime.identifier, title: Simulators.runtimeName(runtime.runtimeIdentifier, version: runtime.version),
                  path: nil, bytes: runtime.sizeBytes ?? 0, children: [], complete: runtime.sizeBytes != nil,
                  action: runtime.deletable == false ? nil : "xcrun simctl runtime delete " + runtime.identifier,
                  sizeState: runtime.sizeBytes == nil ? .unavailable : .complete)
        }.sorted { $0.bytes > $1.bytes }
        var total: Int64 = 0
        for child in kids {
            let sum = total.addingReportingOverflow(child.bytes)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        let complete = kids.allSatisfy { $0.effectiveSizeState == .complete }
        return Entry(id: "simulator-runtimes", title: tr("Simulator runtimes"), path: nil, bytes: total, children: kids,
                     note: tr("separate disk images; remove unused ones with xcrun simctl runtime delete"), complete: complete,
                     sizeState: complete ? .complete : total > 0 ? .incomplete : .unavailable)
    }

    /// The capacity bar describes the home volume; repositories on another disk cannot be
    /// counted against it. They remain available to an explicitly rooted cleanup scan.
    static func projectRoots(home: String) -> [String] {
        var homeStat = stat()
        guard stat(home, &homeStat) == 0 else { return [] }
        return ScanOptions.defaultProjectRoots(home: home).filter { path in
            var rootStat = stat()
            return stat(path, &rootStat) == 0 && rootStat.st_dev == homeStat.st_dev
        }
    }

    private static func priority(_ id: String) -> Int {
        switch id {
        case "trash": return 0
        case "temp": return 1
        case "homebrew": return 2
        case "caches": return 3
        case "projects": return 4
        case "developer": return 5
        case "apps": return 6
        default: return 7
        }
    }

    /// The Data volume as seen from the root: home, /Applications, /Library, /private… all live here.
    static let dataVolumeRoot = "/System/Volumes/Data"

    /// What a folder is called in the list: `~/…` for home, the path people know for the Data
    /// volume (/opt/homebrew, not /System/Volumes/Data/opt/homebrew), and a name for Apple's assets.
    static func displayTitle(_ path: String, home: String) -> String {
        if let asset = assetName(path) { return asset }
        var p = path
        if p.hasPrefix(dataVolumeRoot + "/") { p = String(p.dropFirst(dataVolumeRoot.count)) }
        return FS.tilde(p, home: home)
    }

    static let assetNames: [(String, String)] = [
        ("UAF_FM_CodeLM", "Xcode predictive code completion model"), ("UAF_FM_GenerativeModels", "Apple Intelligence models"),
        ("UAF_FM_Visual", "Apple Intelligence image models"), ("UAF_FM_", "Apple Intelligence model updates"),
        ("UAF_Siri", "Siri voices and language models"), ("Trial_Siri", "Siri voices and language models"),
        ("UAF_Translation", "Translation languages"), ("SpeechTranslation", "Translation languages"),
        ("UAF_Speech", "Dictation and speech recognition"), ("SpeechEndpoint", "Dictation and speech recognition"),
        ("LinguisticData", "Dictionaries and language data"), ("DictionaryServices", "Dictionaries and language data"),
        ("MacinTalk", "Spoken Content voices"), ("VoiceServices", "Spoken Content voices"), ("TTSAX", "Spoken Content voices"),
        ("MacSoftwareUpdate", "Downloaded macOS update"), ("MacSplatSoftwareUpdate", "Downloaded macOS update"),
        ("MacRecoveryOSUpdate", "Recovery update"), ("Font", "Downloadable fonts"), ("AppleDeveloperDocumentation", "Xcode documentation"),
        ("MetalToolchain", "Metal toolchain"), ("UAF_Photos", "Photos models"), ("DesktopPicture", "Wallpapers"),
    ]

    static func assetName(_ path: String) -> String? {
        guard path.contains("/AssetsV2/") else { return nil }
        let name = (path as NSString).lastPathComponent.replacingOccurrences(of: "com_apple_MobileAsset_", with: "")
        guard let match = assetNames.first(where: { name.hasPrefix($0.0) || name.contains($0.0) }) else { return name }
        return tr(match.1) + " (" + name + ")"
    }

    /// Where the assets people can turn off are turned off.
    static func assetAction(_ path: String) -> String? {
        guard path.contains("/AssetsV2/") else { return nil }
        let name = (path as NSString).lastPathComponent
        if name.contains("UAF_FM_CodeLM") { return tr("Xcode → Settings → Intelligence / Text Editing: turn off predictive code completion") }
        if name.contains("UAF_FM") { return tr("System Settings → Apple Intelligence & Siri: turn off Apple Intelligence") }
        if name.contains("Translation") { return tr("System Settings → General → Language & Region → Translation Languages") }
        if name.contains("Siri") { return tr("System Settings → Apple Intelligence & Siri: remove voices you do not use") }
        if name.contains("MacSoftwareUpdate") || name.contains("MacSplat") { return tr("install or skip the pending macOS update in Software Update") }
        return nil
    }

    /// Every place on the Data volume, so the categories add up to the used space instead of
    /// leaving a large remainder. Fixed places first; whatever is left in home, ~/Library and the
    /// volume root is measured too, folder by folder, under "other folders" headings.
    static func spots(home: String, dataRoot: String, userTemp: String, projectRoots: [String]) -> [Spot] {
        let h = { (p: String) in home + "/" + p }
        let library = h("Library")
        let names = { (path: String) in Set(FS.children(path).map { ($0 as NSString).lastPathComponent }) }
        let homeNames = names(home)
        // Project roots nested deeper than home's own folders are counted with the folder holding them.
        let roots = projectRoots.filter { ($0 as NSString).deletingLastPathComponent == home }
        let rootNames = Set(roots.map { ($0 as NSString).lastPathComponent })
        let documents = ["Documents", "Desktop", "Movies", "Music", "Pictures"]
        let homeClaimed = Set(["Library", "Applications", "Downloads", ".Trash"] + documents).union(rootNames)
        let dotFolders = homeNames.filter { $0.hasPrefix(".") && !homeClaimed.contains($0) }.sorted().map(h)
        let otherHome = homeNames.filter { !$0.hasPrefix(".") && !homeClaimed.contains($0) }.sorted().map(h)
        let libraryClaimed: Set<String> = ["Application Support", "Containers", "Group Containers", "Caches", "Developer"]
        let otherLibrary = names(library).subtracting(libraryClaimed).sorted().map { library + "/" + $0 }

        // The volume root: /Applications, home, /opt/homebrew, /usr/local, temp and Apple's assets
        // have their own headings; everything else is system-wide data.
        let data = { (p: String) in dataRoot == "/" ? "/" + p : dataRoot + "/" + p }
        let me = (home as NSString).lastPathComponent
        let assets = data("System/Library/AssetsV2")
        var systemWide: [String] = []
        for name in names(dataRoot.isEmpty ? "/" : dataRoot).sorted() {
            switch name {
            case "Applications", "opt", "usr", "System", "Volumes", "dev", "home", "net": continue
            // Spotlight's index, file-system events and document versions: root only.
            case ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems": continue
            case "Library": systemWide += FS.children(data("Library")).filter { !$0.hasSuffix("/Developer") }.sorted()
            case "Users": systemWide += FS.children(data("Users")).filter { ($0 as NSString).lastPathComponent != me }.sorted()
            case "private":
                for p in FS.children(data("private")).sorted() {
                    switch (p as NSString).lastPathComponent {
                    case "tmp": continue
                    case "var":
                        for v in FS.children(p).sorted() {
                            switch (v as NSString).lastPathComponent {
                            // Swap and the sleep image are the VM volume, measured from the container.
                            case "vm": continue
                            case "folders": systemWide += Self.otherTempFolders(v, mine: userTemp)
                            default: systemWide.append(v)
                            }
                        }
                    default: systemWide.append(p)
                    }
                }
            default: systemWide.append(data(name))
            }
        }
        systemWide += FS.children(data("opt")).filter { !$0.hasSuffix("/homebrew") }.sorted()
        var apple = FS.children(assets).filter { !$0.contains("SimulatorRuntime") }.sorted()
        apple += FS.children(data("System/Library")).filter { !$0.hasSuffix("/AssetsV2") }.sorted()
        apple += FS.children(data("System")).filter { !$0.hasSuffix("/Library") && !$0.hasSuffix("/Volumes") }.sorted()

        return [
            Spot(id: "apps", title: tr("Applications"), paths: ["/Applications", h("Applications")], children: 8),
            Spot(id: "app-data", title: tr("App data (Application Support, Containers)"),
                 paths: [h("Library/Application Support"), h("Library/Containers"), h("Library/Group Containers")], children: 12,
                 note: tr("chat history, app databases and caches; clear them inside each app, or remove what an uninstalled app left behind")),
            Spot(id: "projects", title: tr("Projects and source folders"), paths: roots, children: 12,
                 note: tr("source files and build output together; scan build artifacts to find what can be regenerated")),
            Spot(id: "home-tools", title: tr("Tool and agent folders in your home (~/.codex, ~/.cache …)"), paths: dotFolders,
                 children: 12, note: tr("AI agent sessions, toolchains and package caches; thermo clean ai lists what can go"), expand: false),
            Spot(id: "home-other", title: tr("Other folders in your home"), paths: otherHome, children: 12, expand: false),
            Spot(id: "documents", title: tr("Documents, Desktop and media"), paths: documents.map(h), children: 8),
            Spot(id: "downloads", title: tr("Downloads"), paths: [h("Downloads")], children: 8),
            Spot(id: "library-other", title: tr("Other Library folders (Mail, Messages, …)"), paths: otherLibrary, children: 8, expand: false),
            Spot(id: "caches", title: tr("Caches"), paths: [h("Library/Caches")], children: 6),
            Spot(id: "developer", title: tr("Xcode and simulators"), paths: [h("Library/Developer"), data("Library/Developer")], children: 6,
                 action: "xcrun simctl delete unavailable"),
            Spot(id: "trash", title: tr("Trash"), paths: [h(".Trash")], children: 0, action: tr("Empty the Trash in Finder")),
            // Not X: those are code-sign clones that share their blocks with the app (counted as ~0).
            Spot(id: "temp", title: tr("Temporary files"), paths: [userTemp + "/T", userTemp + "/C", data("private/tmp")], children: 6,
                 note: tr("the system clears most of this itself; agents and build tools leave the rest")),
            Spot(id: "homebrew", title: "Homebrew", paths: [data("opt/homebrew"), data("usr/local")], children: 6,
                 action: "brew cleanup -s --prune=all"),
            Spot(id: "apple-assets", title: tr("Apple downloads (Siri, dictation, translation, Xcode and Apple Intelligence models)"),
                 paths: apple, children: 8,
                 note: tr("macOS downloads these when a feature needs them; turning the feature off in System Settings removes them"), expand: false,
                 reportsDenied: false),
            Spot(id: "system-data", title: tr("System-wide data (/Library, /private/var, other users)"), paths: systemWide, children: 8,
                 note: tr("shared by every user; installers, system databases and logs live here"), expand: false,
                 reportsDenied: false),
        ]
    }

    /// /private/var/folders holds every user's and system service's temp folders; ours (C, T, 0)
    /// is listed except the parts the temp heading measures and X, whose code-sign clones share
    /// their blocks with the apps.
    static func otherTempFolders(_ folders: String, mine: String) -> [String] {
        var out: [String] = []
        for bucket in FS.children(folders).sorted() {
            for user in FS.children(bucket).sorted() {
                // Same folder under another name (/var → /private/var → /System/Volumes/Data/private/var).
                if sameFile(user, mine) {
                    out += FS.children(user).filter { !["T", "C", "X"].contains(($0 as NSString).lastPathComponent) }.sorted()
                } else {
                    out.append(user)
                }
            }
        }
        return out
    }

    static func ownedByMe(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) != 0 || st.st_uid == getuid()
    }

    static func sameFile(_ a: String, _ b: String) -> Bool {
        var x = stat(), y = stat()
        return stat(a, &x) == 0 && stat(b, &y) == 0 && x.st_dev == y.st_dev && x.st_ino == y.st_ino
    }

    struct ContainerVolume: Equatable {
        let name: String
        let roles: [String]
        let bytes: Int64
        let device: String
    }

    /// The other volumes in the startup disk's container: macOS itself, its boot and recovery
    /// copies, and the VM volume where swap lives. They share the free space with the Data volume.
    static func containerVolumes(home: String) -> [ContainerVolume]? {
        var fs = statfs()
        guard statfs(home, &fs) == 0 else { return nil }
        let device = withUnsafeBytes(of: fs.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            .replacingOccurrences(of: "/dev/", with: "")
        let (status, out) = Shell.exec(["/usr/sbin/diskutil", "apfs", "list", "-plist"], timeout: 20)
        guard status == 0 else { return nil }
        return parseVolumes(Data(out.utf8), dataDevice: device)
    }

    static func parseVolumes(_ plist: Data, dataDevice: String) -> [ContainerVolume]? {
        guard let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let containers = root["Containers"] as? [[String: Any]] else { return nil }
        for c in containers {
            let volumes = (c["Volumes"] as? [[String: Any]]) ?? []
            guard volumes.contains(where: { ($0["DeviceIdentifier"] as? String) == dataDevice }) else { continue }
            return volumes.compactMap { v in
                guard let dev = v["DeviceIdentifier"] as? String, dev != dataDevice else { return nil }
                let bytes = (v["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
                return ContainerVolume(name: v["Name"] as? String ?? dev, roles: v["Roles"] as? [String] ?? [], bytes: bytes, device: dev)
            }
        }
        return nil
    }

    /// The container's other volumes as overview entries: macOS (cannot be removed), the VM
    /// volume (swap and the sleep image), and any extra volume someone added.
    static func volumeEntries(_ volumes: [ContainerVolume]) -> [Entry] {
        var out: [Entry] = []
        let vm = volumes.filter { $0.roles.contains("VM") }
        let extra = volumes.filter { $0.roles.isEmpty }
        let system = volumes.filter { !$0.roles.isEmpty && !$0.roles.contains("VM") }
        func kids(_ list: [ContainerVolume]) -> [Entry] {
            list.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }.map {
                Entry(id: "volume/" + $0.device, title: $0.name + ($0.roles.isEmpty ? "" : " (" + $0.roles.joined(separator: ", ") + ")"),
                      path: nil, bytes: $0.bytes, children: [])
            }
        }
        if !system.isEmpty {
            out.append(Entry(id: "macos", title: tr("macOS (system volumes)"), path: nil, bytes: system.reduce(0) { $0 + $1.bytes },
                             children: kids(system), note: tr("the sealed system, its boot files and recovery; macOS manages these"),
                             action: tr("cannot be removed")))
        }
        if !vm.isEmpty {
            out.append(Entry(id: "swap", title: tr("Swap (memory moved to disk)"), path: "/System/Volumes/VM", bytes: vm.reduce(0) { $0 + $1.bytes },
                             children: [], note: tr("swap files and the sleep image; swap grows when memory runs short and shrinks after a restart"),
                             action: tr("close idle apps and agent sessions, or restart")))
        } else if let s = swap() {
            out.append(s)
        }
        if !extra.isEmpty {
            out.append(Entry(id: "volumes", title: tr("Other volumes on this disk"), path: nil, bytes: extra.reduce(0) { $0 + $1.bytes },
                             children: kids(extra), note: tr("volumes added in Disk Utility; they share this disk's free space")))
        }
        return out
    }

    /// Local Time Machine snapshots hold deleted files' blocks until macOS thins them.
    static func localSnapshots() -> Int {
        let (status, out) = Shell.exec(["/usr/bin/tmutil", "listlocalsnapshots", "/"], timeout: 10)
        guard status == 0 else { return 0 }
        return out.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
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

    public static func cached(from url: URL = cacheURL, now: Date = Date(), localize: Bool = false) -> (SpaceOverview, Date)? {
        guard let data = try? Data(contentsOf: url),
              let overview = try? JSONDecoder().decode(SpaceOverview.self, from: data),
              overview.cancelled != true, overview.sizeVersion == 1, overview.incompleteLocations?.isEmpty != false,
              (overview.language == L10n.current.rawValue || localize),
              let measuredAt = overview.measuredAt, measuredAt <= now, isCurrent(measuredAt: measuredAt, cacheURL: url),
              overview.capacity > 0, overview.free >= 0, overview.free <= overview.capacity,
              overview.purgeable >= 0, overview.duration.isFinite, overview.duration >= 0,
              validEntries(overview.entries) else { return nil }
        if overview.language != L10n.current.rawValue {
            guard let translated = overview.localizedForCurrentLanguage() else { return nil }
            return (translated, measuredAt)
        }
        return (overview, measuredAt)
    }

    /// Only known overview headings and notes are presentation strings. Child paths, counts,
    /// byte sizes and the original measurement date remain unchanged.
    public func localizedForCurrentLanguage() -> SpaceOverview? {
        guard let language, Language(rawValue: language) != nil else { return nil }
        let headings = [
            "apps": "Applications", "app-data": "App data (Application Support, Containers)",
            "projects": "Projects and source folders", "caches": "Caches", "developer": "Xcode and simulators", "trash": "Trash", "temp": "Temporary files",
            "homebrew": "Homebrew", "simulator-runtimes": "Simulator runtimes", "swap": "Swap (memory moved to disk)",
            "other": "Not attributed to a folder",
            "home-tools": "Tool and agent folders in your home (~/.codex, ~/.cache …)", "home-other": "Other folders in your home",
            "documents": "Documents, Desktop and media", "downloads": "Downloads", "library-other": "Other Library folders (Mail, Messages, …)",
            "apple-assets": "Apple downloads (Siri, dictation, translation, Xcode and Apple Intelligence models)",
            "system-data": "System-wide data (/Library, /private/var, other users)", "macos": "macOS (system volumes)",
            "volumes": "Other volumes on this disk"
        ]
        let notes = [
            "projects": "source files and build output together; scan build artifacts to find what can be regenerated",
            "temp": "the system clears most of this itself; agents and build tools leave the rest",
            "simulator-runtimes": "separate disk images; remove unused ones with xcrun simctl runtime delete",
            "swap": "swap files and the sleep image; swap grows when memory runs short and shrinks after a restart",
            "app-data": "chat history, app databases and caches; clear them inside each app, or remove what an uninstalled app left behind",
            "home-tools": "AI agent sessions, toolchains and package caches; thermo clean ai lists what can go",
            "apple-assets": "macOS downloads these when a feature needs them; turning the feature off in System Settings removes them",
            "system-data": "shared by every user; installers, system databases and logs live here",
            "macos": "the sealed system, its boot files and recovery; macOS manages these",
            "volumes": "volumes added in Disk Utility; they share this disk's free space"
        ]
        let actions = [
            "trash": "Empty the Trash in Finder", "macos": "cannot be removed",
            "swap": "close idle apps and agent sessions, or restart"
        ]
        var copy = self
        for index in copy.entries.indices {
            guard let heading = headings[copy.entries[index].id] else { return nil }
            copy.entries[index].title = tr(heading)
            if let note = notes[copy.entries[index].id] { copy.entries[index].note = tr(note) }
            if copy.entries[index].id == "other", copy.entries[index].effectiveSizeState != .complete {
                copy.entries[index].note = tr("Includes unmeasured locations; this residual is not a measured folder size.")
            }
            if copy.entries[index].id == "simulator-runtimes", copy.entries[index].effectiveSizeState == .unavailable, copy.entries[index].children.isEmpty {
                copy.entries[index].note = tr("Simulator runtime sizes could not be checked.")
            }
            if let action = actions[copy.entries[index].id] { copy.entries[index].action = tr(action) }
        }
        copy.language = L10n.current.rawValue
        return copy
    }

    private static func validEntries(_ entries: [Entry]) -> Bool {
        var ids = Set<String>()
        return entries.allSatisfy { $0.complete != false && $0.effectiveSizeState == .complete && $0.bytes >= 0 && ids.insert($0.id).inserted && validEntries($0.children) }
    }

    public func save(to url: URL = Self.cacheURL) {
        guard cancelled != true, sizeVersion == 1, incompleteLocations?.isEmpty != false,
              Self.validEntries(entries), Self.isCurrent(measuredAt: measuredAt, cacheURL: url) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    static func isBundle(_ path: String) -> Bool {
        ["app", "bundle", "framework", "photoslibrary", "musiclibrary", "tvlibrary"].contains((path as NSString).pathExtension.lowercased())
    }
}
