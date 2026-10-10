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

    public static func sample(processes: ProcessTable? = nil) -> MachinePulse {
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
        let table = processes ?? ProcessTable.current(.init(cpu: true))
        return MachinePulse(load1: avg[0], load5: avg[1], cores: ProcessInfo.processInfo.activeProcessorCount,
                            thermal: thermal, memory: memory, swapUsedMB: Int(swap.xsu_used / 1_048_576),
                            hogs: group(table.entries, byMemory: memory != .normal), sampled: Date())
    }

    /// Folds helper processes into their app and returns the busiest programs (plus the biggest
    /// ones when memory is short).
    public static func group(_ procs: [AgentProcess], byMemory: Bool = false, me: pid_t = getpid()) -> [Hog] {
        var byKey: [String: Hog] = [:]
        for p in procs where p.cpu > 0.5 || max(p.footprintKB, p.rssKB) > 200_000 {
            let exe = p.executable ?? ""
            var key = "pid:\(p.pid)"
            var name = p.argv.first.map { ($0 as NSString).lastPathComponent } ?? p.name
            var app: String?
            if let r = exe.range(of: ".app/") {
                let appPath = String(exe[..<r.lowerBound]) + ".app"
                key = appPath
                app = appPath
                name = ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            let agent = ProcessTable.agentNames.contains(name.lowercased()) || exe.contains("/claude/versions/")
            let quittable = p.pid != me && p.uid == getuid() && !agent && !exe.hasPrefix("/System/") && !exe.hasPrefix("/usr/")
            var h = byKey[key] ?? Hog(id: key, name: name, cpu: 0, memoryKB: 0, pids: [], app: app, quittable: quittable)
            h.cpu += p.cpu
            h.memoryKB += max(p.footprintKB, p.rssKB)
            h.pids.append(p.pid)
            h.quittable = h.quittable && quittable
            byKey[key] = h
        }
        var top = Array(byKey.values.sorted { $0.cpu > $1.cpu }.prefix(4).filter { $0.cpu >= 5 })
        if byMemory {
            for h in byKey.values.sorted(by: { $0.memoryKB > $1.memoryKB }).prefix(2) where !top.contains(where: { $0.id == h.id }) {
                top.append(h)
            }
        }
        return top
    }
}
