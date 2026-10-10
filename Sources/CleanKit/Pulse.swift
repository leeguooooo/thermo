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
        public var memoryKB: Int
        public var pids: [Int32]
        /// The .app for GUI programs; quitting goes through the app so it can save its work.
        public var app: String?
        /// False for anything Thermo never offers to stop: other users' or system processes,
        /// AI agent sessions, Thermo itself.
        public var quittable: Bool
        /// Where a command-line program runs (its working directory, `~/…`), e.g. the project a test runner belongs to.
        public var project: String? = nil
        /// Who started it: the agent, terminal or editor up its parent chain ("Claude Code", "Terminal", "Cursor").
        public var owner: String? = nil
    }

    public enum Memory: String, Codable, Sendable { case normal, warning, critical }
    public enum Thermal: String, Codable, Sendable { case nominal, fair, serious, critical }
    /// The headline, most urgent first.
    public enum Verdict: String, Codable, Sendable { case hot, overloaded, memory, busy, ok }

    public var load1: Double
    public var load5: Double
    public var cores: Int
    public var thermal: Thermal
    public var memory: Memory
    public var swapUsedMB: Int
    public var hogs: [Hog]
    public var sampled: Date

    /// Load per core: 1 means every core has work, 2 means twice as much work as cores.
    public var busy: Double { load1 / Double(max(1, cores)) }

    public var verdict: Verdict {
        if thermal == .serious || thermal == .critical { return .hot }
        if busy >= 2 { return .overloaded }
        if memory != .normal { return .memory }
        if busy >= 1 { return .busy }
        return .ok
    }

    public var verdictText: String {
        let load = String(Int(load1.rounded())), n = String(cores)
        switch verdict {
        case .hot: return tr("Your Mac is too hot and is slowing itself down")
        case .overloaded: return tr("Your Mac is overloaded: load %1$@ on %2$@ cores", load, n)
        case .memory: return tr("Memory is running out")
        case .busy: return tr("Your Mac is busy: load %1$@ on %2$@ cores", load, n)
        case .ok: return tr("Nothing is slowing your Mac down right now")
        }
    }

    /// Who or what is behind it, when that can be said.
    public var culpritText: String? {
        // Name a program only when it explains a real share of the load: one core out of a load of
        // 100 is not "the reason".
        if let top = hogs.first, top.cpu >= 50, top.cpu / 100 >= load1 * 0.25 {
            return tr("Mostly %1$@, using %2$@ cores", top.name, String(format: "%.1f", top.cpu / 100))
        }
        // High load without a busy program: processes are waiting, usually on memory or the disk.
        if memory != .normal, let big = hogs.max(by: { $0.memoryKB < $1.memoryKB }) {
            return tr("Memory is tight: %1$@ of swap in use, so programs wait on the disk; %2$@ uses the most memory (%3$@)",
                      String(format: "%.1f GB", Double(swapUsedMB) / 1024), big.name,
                      String(format: "%.1f GB", Double(big.memoryKB) / 1_048_576))
        }
        if busy >= 1 { return tr("No single program stands out; many are waiting on the disk") }
        return nil
    }

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
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return level >= 4 ? .critical : level >= 2 ? .warning : .normal
    }

    /// Load, memory, swap and thermal state around a list of programs.
    static func measure(hogs: [Hog]) -> MachinePulse {
        var avg = [Double](repeating: 0, count: 3)
        getloadavg(&avg, 3)
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        let memory: Memory = level >= 4 ? .critical : level >= 2 ? .warning : .normal
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        let thermal: Thermal
        switch ProcessInfo.processInfo.thermalState {
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        default: thermal = .nominal
        }
        return MachinePulse(load1: avg[0], load5: avg[1], cores: ProcessInfo.processInfo.activeProcessorCount,
                            thermal: thermal, memory: memory, swapUsedMB: Int(swap.xsu_used / 1_048_576),
                            hogs: hogs, sampled: Date())
    }

    /// Folds helper processes into their app and returns the busiest programs (plus the biggest
    /// ones when memory is short).
    /// `limit: nil` returns every program of this user, idle ones included (for `thermo pulse quit`).
    public static func group(_ procs: [AgentProcess], byMemory: Bool = false, me: pid_t = getpid(), limit: Int? = 4) -> [Hog] {
        group(procs.map { Candidate(pid: $0.pid, uid: $0.uid, name: $0.name, cpu: $0.cpu, memoryKB: max($0.footprintKB, $0.rssKB),
                                    details: ProcessDetails(executable: $0.executable, argv: $0.argv, cwd: $0.cwd)) },
              byMemory: byMemory, me: me, limit: limit)
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
    }

    static func group(_ procs: [Candidate], byMemory: Bool, me: pid_t, limit: Int? = 4) -> [Hog] {
        var byKey: [String: Hog] = [:]
        for p in procs where limit == nil || p.cpu > 0.5 || p.memoryKB > 200_000 {
            let exe = p.details.executable ?? ""
            var name = programName(p.details, fallback: p.name)
            // Command-line programs: the same tool in the same folder is one row (e.g. 4 vitest workers).
            var key = "cmd:\(name)|\(p.details.cwd ?? "")"
            var app: String?
            var project: String?
            if let r = exe.range(of: ".app/") {
                let appPath = String(exe[..<r.lowerBound]) + ".app"
                key = appPath
                app = appPath
                name = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
            } else if let cwd = p.details.cwd, cwd != "/" {
                project = tilde(cwd)
            }
            let agent = ProcessTable.agentNames.contains(name.lowercased()) || exe.contains("/claude/versions/")
            let quittable = p.pid != me && p.uid == getuid() && !agent && !exe.hasPrefix("/System/") && !exe.hasPrefix("/usr/")
            var h = byKey[key] ?? Hog(id: key, name: name, cpu: 0, memoryKB: 0, pids: [], app: app, quittable: quittable,
                                      project: project, owner: app == nil ? p.owner : nil)
            h.cpu += p.cpu
            h.memoryKB += p.memoryKB
            h.pids.append(p.pid)
            h.quittable = h.quittable && quittable
            byKey[key] = h
        }
        guard let limit else { return byKey.values.sorted { $0.cpu > $1.cpu } }
        var top = Array(byKey.values.sorted { $0.cpu > $1.cpu }.prefix(limit).filter { $0.cpu >= 5 })
        if byMemory {
            for h in byKey.values.sorted(by: { $0.memoryKB > $1.memoryKB }).prefix(2) where !top.contains(where: { $0.id == h.id }) {
                top.append(h)
            }
        }
        return top
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

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
