import Darwin
import Foundation

/// "Why is this Mac slow?": load against cores, thermal throttling, memory pressure and the
/// programs using the most CPU (helpers folded into their app). Shared by the app's Overview card
/// and `thermo pulse`.
public struct MachinePulse: Codable, Sendable, Equatable {
    /// One program: an app with all its helper processes, or a single command-line process.
    public struct Hog: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        /// Percent of one core (200 = two cores busy).
        public var cpu: Double
        /// KiB; the legacy field name is kept for JSON compatibility.
        public var memoryKB: Int
        public var pids: [Int32]
        /// The .app for GUI programs; quitting goes through the app so it can save its work.
        public var app: String?
        /// False for anything Thermo never offers to stop: other users' or system processes,
        /// AI agent sessions, Thermo itself.
        public var quittable: Bool
        /// Where a command-line program runs (its working directory, `~/…`), e.g. the project a test runner belongs to.
        public var project: String? = nil
        /// An observed agent, terminal or editor in its current parent chain ("Claude Code", "Terminal", "Cursor").
        public var owner: String? = nil
        public var owners: [String]? = nil
        /// Resident mappings (RSS), including shared pages; not subtractable from footprint.
        public var residentKB: Int? = nil
        public var memoryMetric: MemoryMetric? = nil
        /// How long it has been running (its longest-lived process).
        public var uptime: TimeInterval? = nil
        /// Chromium/Electron: the highest renderer id, roughly how many pages it has opened since launch.
        public var pagesOpened: Int? = nil
        /// Its biggest processes (apps with several), largest first.
        public var parts: [Part]? = nil
        /// What to do about it, when there is something clear to do.
        public var advice: Advice? = nil
        /// Captured with the reading, for rechecking before an explicit quit/end action.
        public var processIdentities: [ProcessIdentity]? = nil
        public var applicationIdentity: ProcessIdentity? = nil
        /// The same command-line program running in other folders (other rows), so a row is never
        /// mistaken for every copy of the program.
        public var elsewhere: Elsewhere? = nil
        /// Processes counted in this row: every process of the program in this folder (or app).
        public var processCount: Int? = nil
    }

    /// Other rows of the same command-line program, summed.
    public struct Elsewhere: Codable, Sendable, Equatable {
        public var processes: Int
        /// Folders (`~/…`), biggest first.
        public var projects: [String]
        public var memoryKB: Int
        public var memoryMetric: MemoryMetric?
    }

    /// One process of a multi-process app: the GPU process, a renderer (page), an extension …
    public enum MemoryMetric: String, Codable, Sendable { case footprint, residentEstimate, mixed, unavailable }

    public struct Part: Codable, Sendable, Equatable {
        public var pid: Int32
        /// main | GPU | renderer | extension | network | utility | helper
        public var role: String
        public var memoryKB: Int
        public var residentKB: Int?
        public var memoryMetric: MemoryMetric? = nil
        public var cpu: Double
        public var uptime: TimeInterval?
        /// Parent pid; 1 means its parent has exited and launchd adopted it.
        public var ppid: Int32? = nil
        public var owner: String? = nil
        public var project: String? = nil
    }

    public struct Advice: Codable, Sendable, Equatable {
        /// "restart": quit and reopen the app; it restores its windows and frees what it piled up.
        public var kind: String
        public var text: String
        /// Current footprint: an upper bound, since the reopened app will allocate memory again.
        public var freesKB: Int
        /// What happens to its windows: restoresItself (checked), thermoReopensTabs, unknown.
        public var windows: BrowserSession.Windows? = nil
    }

    public enum Memory: String, Codable, Sendable {
        case normal, warning, critical, unknown
        public var isHigh: Bool { self == .warning || self == .critical }
    }
    public enum Thermal: String, Codable, Sendable { case nominal, fair, serious, critical }
    /// The headline, most urgent first.
    public enum Verdict: String, Codable, Sendable { case hot, disk, overloaded, memory, busy, ok }

    public var load1: Double
    public var load5: Double
    public var cores: Int
    public var thermal: Thermal
    public var memory: Memory
    /// MiB; the legacy field name is kept for JSON compatibility.
    public var swapUsedMB: Int
    /// Size of the swap files on disk.
    public var swapTotalMB: Int = 0
    public var hogs: [Hog]
    public var sampled: Date
    /// Free space on the startup disk. Nearly full, swap cannot grow and every write waits, which
    /// shows up as a huge load with no busy program.
    public var diskFreeBytes: Int64? = nil
    /// Free space plus what macOS can purge on demand (local snapshots, evictable iCloud copies):
    /// the disk is only the bottleneck when even this is nearly gone.
    public var diskAvailableBytes: Int64? = nil

    /// Below this the disk is the bottleneck; below `diskLowBytes` it is worth a word.
    public static let diskCriticalBytes: Int64 = 2_000_000_000
    public static let diskLowBytes: Int64 = 5_000_000_000
    var diskCritical: Bool { (diskAvailableBytes ?? diskFreeBytes ?? .max) < Self.diskCriticalBytes }

    /// Load per core: 1 means every core has work, 2 means twice as much work as cores.
    public var busy: Double { load1 / Double(max(1, cores)) }

    public var verdict: Verdict {
        if thermal == .serious || thermal == .critical { return .hot }
        if diskCritical { return .disk }
        if busy >= 2 { return .overloaded }
        if memory.isHigh { return .memory }
        if busy >= 1 { return .busy }
        return .ok
    }

    public var verdictText: String {
        let load = String(Int(load1.rounded())), n = String(cores)
        switch verdict {
        case .hot: return tr("Your Mac is too hot and is slowing itself down")
        case .disk: return tr("The disk is almost full: %1$@ left", Self.bytes(diskFreeBytes ?? 0))
        case .overloaded: return tr("Your Mac is overloaded: load %1$@ on %2$@ cores", load, n)
        case .memory: return tr("Memory is running out")
        case .busy: return tr("Your Mac is busy: load %1$@ on %2$@ cores", load, n)
        case .ok: return tr("No CPU, memory or thermal bottleneck is detected in this reading")
        }
    }

    public struct NextStep: Codable, Sendable, Equatable {
        public let kind: String
        public let program: String?
        public let text: String
    }

    /// A next step tied to the currently observed pressure, rather than any app's age alone.
    public var nextStep: NextStep? {
        if diskCritical, thermal != .serious, thermal != .critical {
            return NextStep(kind: "freeDisk", program: nil,
                            text: tr("Free disk space first (Thermo → Disk, or thermo clean); quitting programs will not help while the disk is full."))
        }
        if thermal == .serious || thermal == .critical || busy >= 2 {
            return NextStep(kind: "pauseWork", program: hogs.max(by: { $0.cpu < $1.cpu })?.name,
                            text: tr("Pause work you can postpone, then check CPU load and thermal pressure again."))
        }
        if memory.isHigh {
            let target = hogs.filter { $0.quittable && $0.memoryKB >= 512 * 1024 }.max { $0.memoryKB < $1.memoryKB }
            if let target, ChromeInspector.isBrowser(target.name) {
                return NextStep(kind: "inspectBrowser", program: target.name,
                                text: tr("Check %1$@'s pages first; close unused heavy pages before considering a full restart.", target.name))
            }
            if let target {
                return NextStep(kind: "reviewApp", program: target.name,
                                text: tr("If you are not using %1$@, save its work and quit it, then check memory pressure again.", target.name))
            }
            return NextStep(kind: "pauseWork", program: nil,
                            text: tr("Pause work in the apps you control, then check memory pressure again."))
        }
        if busy >= 1 {
            return NextStep(kind: "pauseWork", program: nil,
                            text: tr("Pause work you can postpone, then check CPU load and thermal pressure again."))
        }
        return nil
    }

    /// Who or what is behind it, when that can be said.
    public var culpritText: String? {
        if diskCritical {
            return tr("With only %1$@ free, macOS cannot grow swap or write caches, so programs stall waiting on the disk; that is what the load measures.",
                      Self.bytes(diskFreeBytes ?? 0))
        }
        // Name a program only when it explains a real share of the load: one core out of a load of
        // 100 is not "the reason".
        if let top = hogs.first, top.cpu >= 50, top.cpu / 100 >= load1 * 0.25 {
            return tr("Mostly %1$@, using %2$@ cores", top.name, String(format: "%.1f", top.cpu / 100))
        }
        // High load without a busy program: processes are waiting, usually on memory or the disk.
        if memory.isHigh || (busy >= 1 && swapUsedMB >= 4096), let big = hogs.max(by: { $0.memoryKB < $1.memoryKB }) {
            if swapUsedMB >= 4096 {
                // Say it plainly: memory lives on the disk now, and everything waits for the disk.
                return tr("%1$@ of memory has been moved to the disk, memory pressure may be contributing to slow responses. %2$@ uses the most (%3$@).",
                          Self.gb(swapUsedMB * 1024), big.name, Self.gb(big.memoryKB))
            }
            return tr("Memory is tight: %1$@ of swap in use, so programs wait on the disk; %2$@ uses the most memory (%3$@)",
                      MemoryFormat.string(mebibytes: swapUsedMB), big.name,
                      MemoryFormat.string(kibibytes: big.memoryKB))
        }
        if busy >= 1 { return tr("Load is high, but no single program stands out.") }
        return nil
    }

    /// A disk getting full, said before it becomes the bottleneck.
    public var diskText: String? {
        guard let free = diskFreeBytes, free < Self.diskLowBytes, !diskCritical else { return nil }
        return tr("Only %1$@ of disk space is left; when it runs out, swap cannot grow and everything slows down.", Self.bytes(free))
    }

    static func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    /// Swap files fill the disk too; say so once they are big.
    public var swapDiskText: String? {
        guard swapTotalMB >= 8192 else { return nil }
        return tr("Swap files take %1$@ of disk space; macOS gives it back once memory frees up.", Self.gb(swapTotalMB * 1024))
    }

    static func gb(_ kb: Int) -> String { MemoryFormat.string(kibibytes: kb) }

    // MARK: sampling

    /// One-off sample (the CLI): measures CPU over a short window. The app keeps a `PulseSampler`
    /// so each refresh costs one cheap pass instead.
    public static func sample(processes: ProcessTable? = nil) -> MachinePulse {
        if processes == nil { return PulseSampler().sample() }
        return measure(hogs: group(processes!.entries, byMemory: memoryLevel() != .normal))
    }

    static func memoryLevel() -> Memory {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .unknown }
        switch level { case 1: return .normal; case 2: return .warning; case 4: return .critical; default: return .unknown }
    }

    /// Load, memory, swap and thermal state around a list of programs.
    static func measure(hogs: [Hog]) -> MachinePulse {
        var avg = [Double](repeating: 0, count: 3)
        getloadavg(&avg, 3)
        let memory = memoryLevel()
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        let thermal: Thermal
        switch ProcessInfo.processInfo.thermalState {
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        default: thermal = .nominal
        }
        let relevantHogs = hogs.map { hog -> Hog in
            var hog = hog
            if !memory.isHigh { hog.advice = nil }
            return hog
        }
        let volume = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return MachinePulse(load1: avg[0], load5: avg[1], cores: ProcessInfo.processInfo.activeProcessorCount,
                            thermal: thermal, memory: memory, swapUsedMB: Int(swap.xsu_used / 1_048_576),
                            swapTotalMB: Int(swap.xsu_total / 1_048_576), hogs: relevantHogs, sampled: Date(),
                            diskFreeBytes: volume?.volumeAvailableCapacity.map(Int64.init),
                            diskAvailableBytes: volume?.volumeAvailableCapacityForImportantUsage)
    }

    /// Folds helper processes into their app and returns the busiest programs (plus the biggest
    /// ones when memory is short).
    /// `limit: nil` returns every program of this user, idle ones included (for `thermo pulse quit`).
    public static func group(_ procs: [AgentProcess], byMemory: Bool = false, me: pid_t = getpid(), limit: Int? = 4,
                             owner: (AgentProcess) -> String? = { _ in nil }) -> [Hog] {
        group(procs.map { p in
            let reading = p.memoryReading ?? ProcessMemoryReading(footprintKB: p.footprintKB > 0 ? p.footprintKB : nil,
                                                                  residentKB: p.rssKB)
            return Candidate(pid: p.pid, uid: p.uid, name: p.name, cpu: p.cpu,
                             memoryKB: reading.footprintKB ?? reading.residentKB ?? 0,
                             details: ProcessDetails(executable: p.executable, argv: p.argv, cwd: p.cwd),
                             owner: owner(p), residentKB: reading.residentKB, uptime: p.elapsed > 0 ? p.elapsed : nil,
                             memoryMetric: reading.footprintKB != nil ? .footprint : reading.residentKB != nil ? .residentEstimate : .unavailable,
                             ppid: p.ppid)
        }, byMemory: byMemory, me: me, limit: limit)
    }

    /// A process worth considering, with what it takes to name it.
    struct Candidate {
        var pid: pid_t
        var uid: uid_t
        var name: String
        var cpu: Double
        var memoryKB: Int
        var details: ProcessDetails
        var owner: String? = nil
        var residentKB: Int? = nil
        var uptime: TimeInterval? = nil
        var memoryMetric: MemoryMetric = .footprint
        var ppid: pid_t? = nil
    }

    static func group(_ procs: [Candidate], byMemory: Bool, me: pid_t, limit: Int? = 4) -> [Hog] {
        var byKey: [String: Hog] = [:]
        // Every process given is counted; the size threshold applies to whole programs, so a row
        // never sums only its bigger processes.
        for p in procs {
            let (key, name, app) = groupKey(p.details, fallback: p.name)
            let exe = p.details.executable ?? ""
            var project: String?
            if app == nil, let cwd = p.details.cwd, cwd != "/" { project = tilde(cwd) }
            let agent = ProcessTable.agentNames.contains(name.lowercased()) || exe.contains("/claude/versions/")
            let quittable = p.pid != me && p.uid == getuid() && !agent && !exe.hasPrefix("/System/") && !exe.hasPrefix("/usr/")
            // In place: copying the row out and back would copy its pids and parts for every process.
            func add(_ h: inout Hog) {
                if app == nil, !h.pids.isEmpty, h.owner != p.owner || h.owners != nil {
                    // Owners disagree: keep each, claim none for the row.
                    var owners = h.owners ?? [h.owner ?? unknownOwner]
                    let o = p.owner ?? unknownOwner
                    if !owners.contains(o) { owners.append(o) }
                    h.owners = owners.count > 1 ? owners : nil
                    h.owner = owners.count > 1 ? nil : p.owner
                }
                if h.pids.isEmpty { h.memoryMetric = p.memoryMetric }
                else if h.memoryMetric != p.memoryMetric { h.memoryMetric = .mixed }
                h.cpu += p.cpu
                h.memoryKB += p.memoryKB
                h.pids.append(p.pid)
                h.quittable = h.quittable && quittable
                if h.pids.count == 1 { h.residentKB = p.residentKB }
                else if let r = p.residentKB, let existing = h.residentKB { h.residentKB = existing + r }
                else { h.residentKB = nil }
                if let u = p.uptime, u > (h.uptime ?? 0) { h.uptime = u }
                if let id = rendererID(p.details.argv), id > (h.pagesOpened ?? 0) { h.pagesOpened = id }
                do {
                    if h.parts == nil { h.parts = [] }
                    h.parts!.append(Part(pid: p.pid, role: role(p.details.argv), memoryKB: p.memoryKB, residentKB: p.residentKB,
                                      memoryMetric: p.memoryMetric, cpu: p.cpu, uptime: p.uptime,
                                      ppid: p.ppid, owner: p.owner, project: project))
                }
            }
            add(&byKey[key, default: Hog(id: key, name: name, cpu: 0, memoryKB: 0, pids: [], app: app, quittable: quittable,
                                         project: project, owner: app == nil ? p.owner : nil)])
        }
        let byName = Dictionary(grouping: byKey.values.filter { $0.app == nil }, by: \.name)
        for (k, var h) in byKey {
            // Keep the full inventory for drill-down; presentation decides what to expand.
            if let parts = h.parts {
                h.parts = parts.sorted { a, b in
                    a.memoryKB == b.memoryKB ? a.pid < b.pid : a.memoryKB > b.memoryKB
                }
            }
            h.advice = advice(for: h)
            h.elsewhere = elsewhere(of: h, in: byName[h.name] ?? [])
            h.processCount = h.pids.count
            byKey[k] = h
        }
        guard let limit else { return byKey.values.sorted { $0.cpu > $1.cpu } }
        let programs = byKey.values.filter { $0.cpu > 0.5 || $0.memoryKB > 200_000 }
        var top = Array(programs.sorted { $0.cpu > $1.cpu }.prefix(limit).filter { $0.cpu >= 5 })
        if byMemory {
            for h in programs.sorted(by: { $0.memoryKB > $1.memoryKB }).prefix(2) where !top.contains(where: { $0.id == h.id }) {
                top.append(h)
            }
        }
        return top
    }

    static let unknownOwner = "unknown"

    /// What every memory and CPU number in pulse output means; printed with `--json` so a reading
    /// is never an unlabeled "MB".
    public static let units: [String: String] = [
        "memoryKB": "KiB. memoryMetric footprint: phys_footprint, Activity Monitor's Memory column, including compressed memory (also when that is swapped out); residentEstimate: resident set size, used when footprint is unavailable; mixed: both within one row; unavailable: not readable",
        "residentKB": "KiB resident set size (RSS) at sampling: pages in RAM now, shared pages counted in every process; not comparable with footprint",
        "cpu": "percent of one core (200 = two cores) over the sampling window",
        "swapUsedMB": "MiB of swap in use, whole machine",
        "uptime": "seconds since the row's longest-running process started",
    ]

    /// Which programs pulse lists and what a row counts.
    public static let selection = "programs: up to 4 using at least 5% CPU, plus the 2 largest by memory when memory is tight. A row is an app with all its processes, or one command-line program in one folder with all its processes there (processCount); elsewhere sums the same program in other folders. thermo pulse inspect NAME lists every copy."

    /// The row a process belongs to: its app, or the same command-line tool in the same folder
    /// (e.g. 4 vitest workers).
    static func groupKey(_ d: ProcessDetails, fallback: String) -> (key: String, name: String, app: String?) {
        let exe = d.executable ?? ""
        if let r = exe.range(of: ".app/") {
            let appPath = String(exe[..<r.lowerBound]) + ".app"
            return (appPath, ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension, appPath)
        }
        let name = programName(d, fallback: fallback)
        return ("cmd:\(name)|\(d.cwd ?? "")", name, nil)
    }

    /// The same command-line program in other rows (other folders), summed.
    static func elsewhere<S: Sequence>(of h: Hog, in all: S) -> Elsewhere? where S.Element == Hog {
        guard h.app == nil else { return nil }
        let others = all.filter { $0.app == nil && $0.name == h.name && $0.id != h.id }.sorted { $0.memoryKB > $1.memoryKB }
        guard !others.isEmpty else { return nil }
        let metrics = Set(others.compactMap(\.memoryMetric))
        return Elsewhere(processes: others.reduce(0) { $0 + $1.pids.count },
                         projects: others.map { $0.project ?? unknownOwner },
                         memoryKB: others.reduce(0) { $0 + $1.memoryKB },
                         memoryMetric: metrics.count == 1 ? metrics.first : metrics.isEmpty ? nil : .mixed)
    }

    /// What a Chromium / Electron helper is, from its `--type=` flags.
    static func role(_ argv: [String]) -> String {
        func has(_ prefix: String) -> Bool { argv.contains { $0.hasPrefix(prefix) } }
        if has("--type=gpu-process") { return "GPU" }
        if has("--type=renderer") { return has("--extension-process") ? "extension" : "renderer" }
        if has("--type=utility") { return argv.contains { $0.contains("NetworkService") } ? "network" : "utility" }
        if has("--type=") { return "helper" }
        return "main"
    }

    /// A part's role, for people ("page" rather than "renderer").
    public static func roleName(_ role: String) -> String {
        switch role {
        case "GPU": return tr("GPU")
        case "renderer": return tr("page")
        case "extension": return tr("extension")
        case "network": return tr("network")
        case "utility": return tr("utility")
        case "main": return tr("main")
        default: return tr("helper")
        }
    }

    /// Memory pressure and thermal state as words.
    public static func memoryName(_ m: Memory) -> String {
        switch m { case .normal: return tr("normal"); case .warning: return tr("tight"); case .critical: return tr("running out"); case .unknown: return tr("unavailable") }
    }

    public static func thermalName(_ t: Thermal) -> String {
        switch t {
        case .nominal: return tr("normal")
        case .fair: return tr("warm")
        case .serious: return tr("hot, slowing down")
        case .critical: return tr("critical, slowing down")
        }
    }

    /// `--renderer-client-id=1975`: Chromium numbers every renderer it starts.
    static func rendererID(_ argv: [String]) -> Int? {
        argv.lazy.compactMap { a -> Int? in
            guard a.hasPrefix("--renderer-client-id=") else { return nil }
            return Int(a.dropFirst("--renderer-client-id=".count))
        }.first
    }

    /// Optional advice for a large app under pressure. Age/size is not a leak diagnosis,
    /// and no footprint/RSS difference is treated as per-process swap.
    static func advice(for h: Hog) -> Advice? {
        guard h.app != nil, h.quittable, let up = h.uptime, up >= 12 * 3600, h.memoryKB >= 2 * 1_048_576 else { return nil }
        // A large footprint alone does not prove a leak or per-task swap.
        guard h.memoryMetric == nil || h.memoryMetric == .footprint, h.memoryKB >= 6 * 1_048_576 else { return nil }
        let hours = String(Int(up / 3600))
        var text: String
        if let pages = h.pagesOpened, pages >= 100 {
            text = tr("%1$@ has run for %2$@ hours and opened about %3$@ pages; it currently uses %4$@. Restarting may release accumulated memory.",
                      h.name, hours, String(pages), gb(h.memoryKB))
        } else {
            text = tr("%1$@ has run for %2$@ hours; it currently uses %3$@. Restarting may release accumulated memory.", h.name, hours, gb(h.memoryKB))
        }
        // Only promise what was checked.
        let windows = BrowserSession.windows(for: h.name)
        text = sentences(text, restartNote(windows))
        return Advice(kind: "restart", text: text, freesKB: h.memoryKB, windows: windows)
    }

    /// Two sentences as one (no space after a Chinese full stop).
    public static func sentences(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : a + (a.hasSuffix("。") ? "" : " ") + b
    }

    /// What restarting does to the app's windows, in plain words.
    public static func restartNote(_ w: BrowserSession.Windows) -> String {
        switch w {
        case .restoresItself: return tr("It reopens your tabs itself.")
        case .thermoReopensTabs: return tr("It is not set to reopen its tabs, so Thermo saves them and opens them again; anything typed and not sent is lost.")
        case .unknown: return tr("Save your work first: it may not reopen its windows.")
        }
    }

    static let interpreters: Set<String> = ["node", "python", "python3", "ruby", "bun", "deno", "java", "perl", "php", "uv", "npx", "tsx", "ts-node"]

    /// "vitest" rather than "node": for an interpreter, the package or script it runs.
    static func programName(_ d: ProcessDetails, fallback: String) -> String {
        let first = d.argv.first.map { ($0 as NSString).lastPathComponent } ?? (d.executable as NSString?)?.lastPathComponent ?? fallback
        guard interpreters.contains(first.lowercased()) || first.lowercased().hasPrefix("python") else { return first.isEmpty ? fallback : first }
        for arg in d.argv.dropFirst() where !arg.hasPrefix("-") {
            // …/node_modules/.pnpm/vitest@1/node_modules/vitest/dist/x.js → vitest; …/node_modules/.bin/tsc → tsc
            let parts = arg.split(separator: "/").map(String.init)
            if let i = parts.lastIndex(of: "node_modules"), i + 1 < parts.count {
                let next = parts[i + 1]
                if next == ".bin", i + 2 < parts.count { return parts[i + 2] }
                if next.hasPrefix("@"), i + 2 < parts.count { return next + "/" + parts[i + 2] }
                if next != ".pnpm" { return next }
            }
            if arg.contains("/") || arg.contains(".") {
                let base = ((arg as NSString).lastPathComponent as NSString).deletingPathExtension
                if !base.isEmpty, !["index", "main", "cli", "bin", "server"].contains(base) { return base }
                // index.js and friends say little; their folder says more.
                let dir = ((arg as NSString).deletingLastPathComponent as NSString).lastPathComponent
                if !dir.isEmpty, dir != "dist", dir != "bin", dir != "lib" { return dir }
            }
            if !arg.contains("/") { return arg }  // e.g. `python -m pytest` → handled below
        }
        if let m = d.argv.firstIndex(of: "-m"), m + 1 < d.argv.count { return d.argv[m + 1] }
        return first
    }

    private static let home = NSHomeDirectory()

    static func tilde(_ path: String) -> String {
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
