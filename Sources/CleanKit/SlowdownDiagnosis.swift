import AgentCore
import Darwin
import Foundation

/// "Why is my Mac slow right now?" as one to three culprits with an estimated effect, instead of
/// a flat list. Pure over a snapshot so the incident behind issues #10/#11 can be replayed in tests;
/// `SlowdownSampler` produces the snapshot from the live machine over time.
public struct SlowdownProcess: Codable, Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: UInt32
    /// `p_comm`, at most 16 bytes.
    public var name: String
    public var executable: String?
    public var argv: [String]
    public var cwd: String?
    /// Percent of one core over the latest sampling window.
    public var cpu: Double
    /// Average percent of one core since the process started (CPU time / age).
    public var cpuLifetime: Double?
    /// How long it has stayed at or above `SlowdownDiagnosis.busyCPU` across samples; nil when unobserved.
    public var busyFor: TimeInterval?
    /// phys_footprint: Activity Monitor's Memory column, compressed and swapped pages included.
    public var footprintKB: Int
    public var residentKB: Int?
    public var elapsed: TimeInterval
    /// Disk writes per second over the latest window.
    public var writeBytesPerSecond: Double?
    public var started: Date?
    /// CPU of children that already exited, percent of one core: over the latest window, and averaged
    /// over its life. A parent re-spawning short-lived workers shows it here and nowhere else.
    public var childCPU: Double? = nil
    public var childCPULifetime: Double? = nil
    /// Short-lived children seen during sampling, by command (friendly name → distinct PIDs).
    public var youngChildren: [String: Int]? = nil

    public init(pid: Int32, ppid: Int32, uid: UInt32 = getuid(), name: String, executable: String? = nil, argv: [String] = [],
                cwd: String? = nil, cpu: Double = 0, cpuLifetime: Double? = nil, busyFor: TimeInterval? = nil,
                footprintKB: Int = 0, residentKB: Int? = nil, elapsed: TimeInterval = 0,
                writeBytesPerSecond: Double? = nil, started: Date? = nil) {
        self.pid = pid; self.ppid = ppid; self.uid = uid; self.name = name; self.executable = executable; self.argv = argv
        self.cwd = cwd; self.cpu = cpu; self.cpuLifetime = cpuLifetime; self.busyFor = busyFor; self.footprintKB = footprintKB
        self.residentKB = residentKB; self.elapsed = elapsed; self.writeBytesPerSecond = writeBytesPerSecond; self.started = started
    }

    /// The .app the executable lives in, if any.
    public var app: String? {
        guard let exe = executable, let r = exe.range(of: ".app/") else { return nil }
        return String(exe[..<r.lowerBound]) + ".app"
    }
}

public struct SlowdownSystem: Codable, Sendable, Equatable {
    public var memoryBytes: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: MachinePulse.Memory
    public var load1: Double
    public var cores: Int

    public init(memoryBytes: UInt64, swapUsed: UInt64, swapTotal: UInt64, pressure: MachinePulse.Memory, load1: Double, cores: Int) {
        self.memoryBytes = memoryBytes; self.swapUsed = swapUsed; self.swapTotal = swapTotal
        self.pressure = pressure; self.load1 = load1; self.cores = cores
    }

    public static func read() -> SlowdownSystem {
        let b = MemoryBreakdown.read()
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        return SlowdownSystem(memoryBytes: ProcessInfo.processInfo.physicalMemory, swapUsed: b?.swapUsed ?? 0,
                              swapTotal: b?.swapFiles ?? 0, pressure: b?.pressure ?? MachinePulse.memoryLevel(),
                              load1: load[0], cores: ProcessInfo.processInfo.activeProcessorCount)
    }

    public enum Strain: String, Codable, Sendable, Comparable {
        case none, tight, exhausted
        public static func < (a: Strain, b: Strain) -> Bool { a.rank < b.rank }
        var rank: Int { switch self { case .none: return 0; case .tight: return 1; case .exhausted: return 2 } }
    }

    /// Exhausted: macOS reports critical pressure, or swap is nearly out of room (< 1 GB left of
    /// what it has allocated) while holding at least half of RAM. Swap size alone is not pressure.
    public var memoryStrain: Strain {
        let left = swapTotal > swapUsed ? swapTotal - swapUsed : 0
        if pressure == .critical || (swapTotal > 0 && left < 1 << 30 && swapUsed >= memoryBytes / 2) { return .exhausted }
        if pressure == .warning || swapUsed >= memoryBytes / 2 { return .tight }
        return .none
    }

    public var cpuStrain: Strain {
        let perCore = load1 / Double(max(1, cores))
        return perCore >= 2 ? .exhausted : perCore >= 1 ? .tight : .none
    }
}

public struct SlowdownCulprit: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Sustained high CPU.
        case runaway
        /// Long-running, large, and doing nothing: holding memory it will not give back.
        case stuck
        /// Its parent is gone (PPID 1) and it is still busy or large.
        case orphan
        /// A parent piling up children it never reaps (e.g. codex app-server with 165).
        case leakyParent
        /// A large GUI app under memory pressure.
        case heavyApp
        /// Many agent sessions open, most of them idle.
        case agentSessions
        /// A long-lived parent re-spawning short-lived workers; their CPU only shows up summed.
        case respawnChurn
        /// The same MCP server idle in many sessions, some of them already ended.
        case idleMCP
    }

    public enum Action: String, Codable, Sendable {
        /// SIGTERM, then SIGKILL; `thermo pulse end PID`.
        case end
        /// Restart the app that owns the process; `thermo pulse restart NAME`.
        case restartApp
        /// Suggest quitting; never done automatically. `thermo pulse quit NAME`.
        case quitApp
        /// Show the list; the user decides.
        case review
    }

    public var id: String { "\(kind.rawValue):\(pids.first ?? 0)" }
    public var kind: Kind
    public var action: Action
    /// The friendly name ("codegraph MCP server", "Douyin AR").
    public var name: String
    /// Who launched it ("codex app-server · PID 39971", "parent exited").
    public var launcher: String?
    public var project: String?
    /// The processes the action applies to, main one first.
    public var pids: [Int32]
    public var identities: [ProcessIdentity]?
    public var app: String?
    public var cpu: Double
    public var memoryKB: Int
    /// What acting is expected to free.
    public var freesKB: Int
    public var children: Int?
    public var elapsed: TimeInterval?
    /// Why it was picked, in one sentence.
    public var evidence: String
    /// What to do, in one or two sentences.
    public var guidance: String
    /// The CLI command that does it.
    public var command: String?
    /// For agent sessions: one line each.
    public var sessions: [String]?
    var score: Double
    /// The processes whose memory `freesKB` counts, so totals across culprits never count one twice.
    public var covered: [Int32]? = nil
    /// The row name the pulse list uses for it ("codegraph", "Douyin AR"), for highlighting.
    public var program: String? = nil
}

public struct SlowdownDiagnosis: Codable, Sendable {
    public var sampled: Date
    public var system: SlowdownSystem
    public var memoryStrain: SlowdownSystem.Strain
    public var cpuStrain: SlowdownSystem.Strain
    public var headline: String
    /// The 1–3 programs that explain the slowdown, biggest effect first.
    public var culprits: [SlowdownCulprit]
    /// Worth knowing, not the main cause.
    public var also: [SlowdownCulprit]

    /// Pressure a person would feel: worth a notification.
    public var isReal: Bool { memoryStrain == .exhausted || cpuStrain == .exhausted || culprits.contains { $0.kind == .runaway || $0.kind == .orphan } }

    public static let busyCPU: Double = 80
    public static let busyFor: TimeInterval = 3 * 60

    /// Never named as something to end, whatever it does.
    static let systemNames: Set<String> = ["kernel_task", "WindowServer", "launchd", "loginwindow", "mds", "mds_stores", "mdworker",
                                           "mdworker_shared", "coreaudiod", "Finder", "Dock", "SystemUIServer", "cfprefsd", "logd",
                                           "opendirectoryd", "hidd", "powerd", "configd", "syslogd", "notifyd", "distnoted",
                                           "trustd", "securityd", "runningboardd", "backupd", "spotlightknowledged", "corespotlightd"]

    public static func isSystem(_ p: SlowdownProcess, me: uid_t = getuid()) -> Bool {
        if p.uid != me || p.pid <= 1 || systemNames.contains(p.name) || p.name.hasPrefix("mdworker") { return true }
        let exe = p.executable ?? ""
        return ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"].contains { exe.hasPrefix($0) }
    }

    static func isAgentSession(_ p: SlowdownProcess) -> Bool {
        let first = ((p.argv.first ?? "") as NSString).lastPathComponent.lowercased()
        let exe = (p.executable ?? "").lowercased()
        guard ProcessTable.agentNames.contains(p.name.lowercased()) || ProcessTable.agentNames.contains(first)
                || exe.contains("/claude/versions/") else { return false }
        return !isAppServer(p)
    }

    static func isAppServer(_ p: SlowdownProcess) -> Bool { p.argv.dropFirst().first == "app-server" }

    static func isMCP(_ p: SlowdownProcess) -> Bool {
        let lower = p.argv.map { $0.lowercased() }
        return lower.contains("--mcp") || lower.dropFirst().contains("mcp") || lower.contains { $0.hasSuffix("-mcp") || $0.contains("mcp-server") || $0.contains("/mcp/") }
            || p.name.lowercased().contains("mcp")
    }

    public static func friendlyName(_ p: SlowdownProcess) -> String {
        if let app = p.app, p.executable?.contains(".app/Contents/MacOS/") == true, !isAppServer(p) {
            return ((app as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        let base = MachinePulse.programName(ProcessDetails(executable: p.executable, argv: p.argv, cwd: p.cwd), fallback: p.name)
        if isAppServer(p) { return "\(base) app-server" }
        if isAgentSession(p) { return p.name.lowercased() == "claude" || base.lowercased() == "claude" ? "Claude Code" : base }
        return isMCP(p) && !base.lowercased().contains("mcp") ? tr("%1$@ MCP server", base) : base
    }

    /// The tool a binary belongs to, from where it is installed: "wechat-use" for
    /// ~/.local/share/wechat-use/…, the package for …/node_modules/<pkg>/…, the formula for Cellar.
    static func toolName(_ exe: String?) -> String? {
        guard let exe else { return nil }
        let parts = exe.split(separator: "/").map(String.init)
        for marker in ["share", "node_modules", "Cellar", "opt"] {
            if let i = parts.firstIndex(of: marker), i + 1 < parts.count - 1 {
                let name = parts[i + 1]
                if !name.hasPrefix("."), !["lib", "bin", "homebrew"].contains(name) { return name }
            }
        }
        return nil
    }

    static func tilde(_ path: String?) -> String? {
        guard let path, path != "/" else { return nil }
        let home = NSHomeDirectory()
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    public static func diagnose(_ processes: [SlowdownProcess], system: SlowdownSystem, me: Int32 = getpid(),
                                uid: uid_t = getuid(), sampled: Date = Date(),
                                launchdLabel: (String) -> String? = LaunchAgentLabels.label(forExecutable:),
                                packageVersion: (SlowdownProcess) -> PackageVersion? = PackageVersion.installed) -> SlowdownDiagnosis {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [Int32: [SlowdownProcess]] = [:]
        for p in processes where p.pid != p.ppid { children[p.ppid, default: []].append(p) }
        func descendants(_ pid: Int32) -> [SlowdownProcess] {
            var out: [SlowdownProcess] = [], queue = children[pid] ?? [], seen: Set<Int32> = [pid]
            while let next = queue.popLast() {
                guard seen.insert(next.pid).inserted else { continue }
                out.append(next); queue += children[next.pid] ?? []
            }
            return out
        }
        /// The nearest agent session, agent app-server or app above `p`.
        func launcher(_ p: SlowdownProcess) -> (text: String?, root: SlowdownProcess?) {
            if p.ppid == 1 { return (tr("parent exited (adopted by launchd)"), nil) }
            var current = byPID[p.ppid], hops = 0
            while let c = current, hops < 32 {
                if isAgentSession(c) || isAppServer(c) {
                    return ("\(friendlyName(c)) · PID \(c.pid)" + (tilde(c.cwd).map { " · " + $0 } ?? ""), c)
                }
                if let app = c.app { return (((app as NSString).lastPathComponent as NSString).deletingPathExtension, c) }
                if c.ppid <= 1 { break }
                current = byPID[c.ppid]; hops += 1
            }
            return (byPID[p.ppid].map { "\(friendlyName($0)) · PID \($0.pid)" }, nil)
        }
        let memoryStrain = system.memoryStrain, cpuStrain = system.cpuStrain
        // Memory a person feels: weigh freed memory more when memory is the problem.
        let memoryWeight: Double = memoryStrain == .exhausted ? 3 : memoryStrain == .tight ? 1.5 : 0.5
        let cpuWeight: Double = cpuStrain == .none ? 1 : 2
        func score(cpu: Double, freesKB: Int, certain: Bool) -> Double {
            Double(freesKB) / 1_048_576 * memoryWeight + cpu / 100 * cpuWeight + (certain ? 3 : 0)
        }
        func identity(_ p: SlowdownProcess) -> ProcessIdentity? {
            guard let started = p.started, let exe = p.executable else { return nil }
            return ProcessIdentity(pid: p.pid, uid: p.uid, started: started, executable: exe)
        }
        func gb(_ kb: Int) -> String { MemoryFormat.string(kibibytes: kb) }
        func endCommand(_ pids: [Int32]) -> String { "thermo pulse end " + pids.map(String.init).joined(separator: " ") }

        var found: [SlowdownCulprit] = []
        var claimed = Set<Int32>()
        let mine = processes.filter { $0.pid != me && !isSystem($0, me: uid) }

        for p in mine where !claimed.contains(p.pid) && !isAgentSession(p) && !isAppServer(p) {
            let isGUI = p.app != nil && p.executable?.contains(".app/Contents/MacOS/") == true
            let (launchedBy, root) = launcher(p)
            let tree = isGUI ? [] : descendants(p.pid)
            let treeKB = p.footprintKB + tree.reduce(0) { $0 + $1.footprintKB }
            let pids = [p.pid] + tree.map(\.pid)
            let sustained = (p.busyFor ?? 0) >= busyFor || ((p.cpuLifetime ?? 0) >= 50 && p.elapsed >= 10 * 60)
            let orphan = p.ppid == 1 && p.app == nil
            let name = friendlyName(p)
            if !isGUI, p.cpu >= busyCPU, sustained {
                let since = MemorySuspects.duration((p.busyFor ?? 0) >= busyFor ? p.busyFor! : p.elapsed)
                var evidence = tr("%1$@ has used %2$@ of a core for %3$@.", name, String(format: "%.0f%%", p.cpu), since)
                if orphan { evidence = MachinePulse.sentences(evidence, tr("Its parent has exited, so nothing is waiting for it.")) }
                if let w = p.writeBytesPerSecond, w >= 5_000_000 {
                    evidence = MachinePulse.sentences(evidence, tr("It is also writing %1$@/s to disk.", ByteFormat.string(Int64(w))))
                }
                found.append(SlowdownCulprit(
                    kind: orphan ? .orphan : .runaway, action: .end, name: name, launcher: launchedBy, project: tilde(p.cwd),
                    pids: pids, identities: identity(p).map { [$0] }, app: nil, cpu: p.cpu, memoryKB: treeKB, freesKB: treeKB,
                    children: tree.isEmpty ? nil : tree.count, elapsed: p.elapsed, evidence: evidence,
                    guidance: orphan ? tr("Safe to end: whatever started it is gone. Thermo asks it to stop, then forces it if it does not.")
                        : tr("Ending it stops the work it is doing; if it belongs to an agent session, that session restarts it when needed."),
                    command: endCommand([p.pid]), sessions: nil,
                    score: score(cpu: p.cpu, freesKB: treeKB, certain: orphan)))
                claimed.insert(p.pid); continue
            }
            // Only tools an agent started (or that lost their parent): an idle dev server, database or VM
            // a person started is big and quiet on purpose.
            let agentTool = orphan || root.map { isAgentSession($0) || isAppServer($0) } == true
            if !isGUI, agentTool, p.footprintKB >= 1_048_576, p.elapsed >= 6 * 3600, p.cpu < 5, (p.busyFor ?? 0) == 0 {
                found.append(SlowdownCulprit(
                    kind: orphan ? .orphan : .stuck, action: .end, name: name, launcher: launchedBy, project: tilde(p.cwd),
                    pids: pids, identities: identity(p).map { [$0] }, app: nil, cpu: p.cpu, memoryKB: treeKB, freesKB: treeKB,
                    children: tree.isEmpty ? nil : tree.count, elapsed: p.elapsed,
                    evidence: tr("%1$@ has run for %2$@ holding %3$@ while using almost no CPU (%4$@): it looks stuck.",
                                 name, MemorySuspects.duration(p.elapsed), gb(p.footprintKB), String(format: "%.1f%%", p.cpu)),
                    guidance: tr("Likely safe to end: a stuck tool does not finish. Ending it frees about %1$@.", gb(treeKB)),
                    command: endCommand([p.pid]), sessions: nil,
                    score: score(cpu: 0, freesKB: treeKB, certain: true)))
                claimed.insert(p.pid)
            }
        }

        // Respawn churn: a long-lived parent starting short-lived workers again and again. Any single
        // reading shows a seconds-old child or nothing; the parent's reaped-children CPU shows the total.
        let shells: Set<String> = ["zsh", "bash", "sh", "fish", "login", "tmux", "screen", "make", "ninja", "xcodebuild", "swift-build", "cargo", "npm", "pnpm", "yarn"]
        for p in mine where !claimed.contains(p.pid) && !isAgentSession(p) && !isAppServer(p) && !shells.contains(p.name)
            && !(p.executable?.contains(".app/Contents/MacOS/") ?? false) {
            guard let kids = p.youngChildren, let (command, seen) = kids.max(by: { $0.value < $1.value }),
                  let lifetime = p.childCPULifetime, lifetime >= 20, p.elapsed >= 10 * 60,
                  (p.childCPU ?? 0) >= 10 || seen >= 2 else { continue }
            let cpu = max(lifetime, p.childCPU ?? 0)
            let name = friendlyName(p)
            let tool = toolName(p.executable)
            var chain: [SlowdownProcess] = [p], up = byPID[p.ppid]
            while let u = up, u.pid > 1, chain.count < 8 { chain.append(u); up = byPID[u.ppid] }
            let label = chain.compactMap { $0.executable.flatMap { launchdLabel($0) } }.first
            let who = tool.map { "\(name) (\($0))" } ?? name
            var guidance = label.map { tr("Stop or restart %1$@ the way it was started: launchctl kickstart -k gui/%2$@/%3$@ restarts it, launchctl bootout gui/%2$@/%3$@ stops it.", who, String(uid), $0) }
                ?? tr("Stop or restart %1$@ with its own command (for example `%2$@ stop`) or quit the tool that started it; ending only the worker does not help, the next one starts seconds later.", who, p.name)
            guidance = MachinePulse.sentences(guidance, tr("This polling looks like a bug or an aggressive default: worth reporting to the author of %1$@.", tool ?? name))
            found.append(SlowdownCulprit(
                kind: .respawnChurn, action: .review, name: name, launcher: launcher(p).text, project: tilde(p.cwd),
                pids: [p.pid], identities: identity(p).map { [$0] }, app: nil, cpu: cpu, memoryKB: p.footprintKB, freesKB: 0,
                children: seen, elapsed: p.elapsed,
                evidence: tr("%1$@ keeps starting short-lived %2$@ processes (%3$@ seen just now); together they use about %4$@ of a core, averaged over %5$@. A single reading only shows a seconds-old %2$@.",
                             name, command, String(seen), String(format: "%.0f%%", cpu), MemorySuspects.duration(p.elapsed)),
                guidance: guidance, command: label.map { "launchctl kickstart -k gui/\(uid)/\($0)" }, sessions: nil,
                score: score(cpu: cpu, freesKB: 0, certain: true)))
            claimed.insert(p.pid)
        }

        // Idle MCP servers, counted across every session: one copy per session adds up.
        do {
            var groups: [String: [SlowdownProcess]] = [:]
            for p in mine where isMCP(p) && !claimed.contains(p.pid) && p.cpu < 2 && p.app == nil { groups[friendlyName(p), default: []].append(p) }
            for (name, members) in groups {
                let total = members.reduce(0) { $0 + $1.footprintKB }
                guard members.count >= 4, total >= 1_048_576 else { continue }
                // Leaked: its parent is gone, or it hangs off an app-server rather than a live session.
                func leaked(_ p: SlowdownProcess) -> Bool {
                    guard p.ppid != 1, let parent = byPID[p.ppid] else { return true }
                    return isAppServer(parent) || !(isAgentSession(parent) || parent.app != nil)
                }
                let stale = members.filter(leaked), live = members.filter { !leaked($0) }
                let staleKB = stale.reduce(0) { $0 + $1.footprintKB }
                let orphans = stale.filter { $0.ppid == 1 }
                let hosts = Set(stale.compactMap { byPID[$0.ppid] }.filter(isAppServer).map(\.pid))
                let each = total / members.count
                var guidance: [String] = []
                for h in hosts.sorted() {
                    guard let host = byPID[h] else { continue }
                    let session = launcher(host).root.map { "\(friendlyName($0)) (PID \($0.pid)" + (tilde($0.cwd).map { ", " + $0 } ?? "") + ")" }
                    let n = stale.filter { $0.ppid == h }.count
                    guidance.append(session.map { tr("%1$@ copies are held by %2$@ (PID %3$@) from sessions that already ended: quit and reopen %4$@; its current task is interrupted, the conversation can be resumed.", String(n), friendlyName(host), String(h), $0) }
                        ?? tr("%1$@ copies are held by %2$@ (PID %3$@) from sessions that already ended: restart it; its current tasks are interrupted.", String(n), friendlyName(host), String(h)))
                }
                if !orphans.isEmpty {
                    guidance.append(tr("%1$@ copies lost their session and can be ended safely.", String(orphans.count)))
                }
                var cost = tr("%1$@ costs about %2$@ per session × %3$@ copies. Consider turning it off globally and enabling it only in the projects that use it.",
                              name, MemoryFormat.string(kibibytes: each), String(members.count))
                if let v = members.compactMap({ packageVersion($0) }).first {
                    cost = MachinePulse.sentences(cost, tr("Installed: %1$@ %2$@; check whether a newer version uses less.", v.name, v.version))
                }
                guidance.append(cost)
                let frees = staleKB > 0 ? staleKB : total
                found.append(SlowdownCulprit(
                    kind: .idleMCP, action: orphans.isEmpty ? .review : .end, name: name, launcher: nil, project: nil,
                    pids: (orphans + stale + live).map(\.pid).reduce(into: [Int32]()) { if !$0.contains($1) { $0.append($1) } },
                    identities: orphans.compactMap(identity), app: nil, cpu: members.reduce(0) { $0 + $1.cpu }, memoryKB: total, freesKB: frees,
                    children: members.count, elapsed: nil,
                    evidence: tr("%1$@ idle copies of %2$@ use %3$@ (about %4$@ each); %5$@ of them belong to sessions that already ended (%6$@), %7$@ to open sessions.",
                                 String(members.count), name, MemoryFormat.string(kibibytes: total), MemoryFormat.string(kibibytes: each),
                                 String(stale.count), MemoryFormat.string(kibibytes: staleKB), String(live.count)),
                    guidance: guidance.joined(separator: " "),
                    command: orphans.isEmpty ? nil : endCommand(orphans.map(\.pid)), sessions: nil,
                    score: score(cpu: 0, freesKB: staleKB + live.reduce(0) { $0 + $1.footprintKB } / 4, certain: !orphans.isEmpty),
                    covered: stale.map(\.pid)))
            }
        }

        // Parents piling up children (codex app-server keeping a full MCP set per finished session).
        // A terminal or an app's own helpers are not this; nested sessions are counted on their own.
        func ownTree(_ pid: Int32) -> [SlowdownProcess] {
            var out: [SlowdownProcess] = [], queue = children[pid] ?? [], seen: Set<Int32> = [pid]
            while let next = queue.popLast() {
                guard seen.insert(next.pid).inserted, !isAgentSession(next), !isAppServer(next), !claimed.contains(next.pid) else { continue }
                out.append(next); queue += children[next.pid] ?? []
            }
            return out
        }
        for p in mine where isAppServer(p) || isAgentSession(p) {
            let tree = ownTree(p.pid)
            let mcpServers = tree.filter(isMCP)
            // A session normally runs a handful of MCP servers; dozens means they were never reaped.
            // Shells and builds under a session are its work, not a leak: only an app-server's sheer count counts.
            guard mcpServers.count >= 20 || (isAppServer(p) && tree.count >= 40) else { continue }
            let total = p.footprintKB + tree.reduce(0) { $0 + $1.footprintKB }
            var tally: [String: Int] = [:]
            for c in tree { tally[friendlyName(c), default: 0] += 1 }
            let counts: [(name: String, count: Int)] = tally.map { (name: $0.key, count: $0.value) }
                .sorted { a, b in a.count == b.count ? a.name < b.name : a.count > b.count }
            let repeated = counts.prefix(4).filter { $0.count > 1 }.map { "\($0.name) ×\($0.count)" }.joined(separator: ", ")
            let name = friendlyName(p)
            let (launchedBy, root) = launcher(p)
            let app = p.app
            let appName = app.map { ((($0 as NSString).lastPathComponent) as NSString).deletingPathExtension }
            let session = root.map { "\(friendlyName($0)) (PID \($0.pid)" + (tilde($0.cwd).map { ", " + $0 } ?? "") + ")" }
            let guidance: String
            if let appName {
                guidance = tr("Restart %1$@: tasks running in it are interrupted; conversations are kept and reopen. Its %2$@ leftover helpers go away with it.", appName, String(tree.count))
            } else if let session {
                guidance = tr("Quit the %1$@ session and start it again: its current task is interrupted, the conversation can be resumed. Its %2$@ leftover helpers go away with it.", session, String(tree.count))
            } else {
                guidance = tr("Restart whatever runs %1$@: its current tasks are interrupted. Its %2$@ leftover helpers go away with it.", name, String(tree.count))
            }
            found.append(SlowdownCulprit(
                kind: .leakyParent, action: app != nil ? .restartApp : .review, name: name, launcher: launchedBy,
                project: tilde(p.cwd), pids: [p.pid], identities: identity(p).map { [$0] }, app: app, cpu: p.cpu + tree.reduce(0) { $0 + $1.cpu },
                memoryKB: total, freesKB: total, children: tree.count, elapsed: p.elapsed,
                evidence: MachinePulse.sentences(
                    tr("%1$@ holds %2$@ child processes (%3$@ MCP servers) using %4$@ in total, running for %5$@.",
                       name, String(tree.count), String(mcpServers.count), gb(total), MemorySuspects.duration(p.elapsed)),
                    repeated.isEmpty ? "" : tr("Repeated: %1$@ — sessions that ended left theirs running.", repeated)),
                guidance: guidance,
                command: appName.map { "thermo pulse restart \"\($0)\"" }, sessions: nil,
                score: score(cpu: 0, freesKB: total, certain: false), covered: [p.pid] + tree.map(\.pid)))
            claimed.insert(p.pid)
            claimed.formUnion(tree.map(\.pid))
        }

        // GUI apps: all of an app's processes together; suggested only, never ended.
        if memoryStrain != .none {
            let apps = Dictionary(grouping: mine.filter { $0.app != nil && !claimed.contains($0.pid) && !isAppServer($0) }, by: { $0.app! })
            for (app, members) in apps {
                let kb = members.reduce(0) { $0 + $1.footprintKB }
                guard kb >= 2 * 1_048_576, !ProcessTable.agentNames.contains(((app as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()) else { continue }
                let name = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
                let main = members.first { $0.executable?.contains(".app/Contents/MacOS/") == true && !($0.executable ?? "").contains("Helper") } ?? members[0]
                found.append(SlowdownCulprit(
                    kind: .heavyApp, action: .quitApp, name: name, launcher: nil, project: nil,
                    pids: [main.pid] + members.map(\.pid).filter { $0 != main.pid }, identities: nil, app: app,
                    cpu: members.reduce(0) { $0 + $1.cpu }, memoryKB: kb, freesKB: kb, children: members.count, elapsed: main.elapsed,
                    evidence: tr("%1$@ uses %2$@ across %3$@ processes.", name, gb(kb), String(members.count)),
                    guidance: tr("If you are not using %1$@, quit it (it may ask to save). Thermo never quits apps on its own.", name),
                    command: "thermo pulse quit \"\(name)\"", sessions: nil,
                    // The user is probably using it: worth half of what a stuck tool is.
                    score: score(cpu: members.reduce(0) { $0 + $1.cpu }, freesKB: kb, certain: false) * 0.5))
            }
        }

        // Many agent sessions: list them; idle ones are what the user can close.
        let sessions = mine.filter { isAgentSession($0) && !claimed.contains($0.pid) }
        if sessions.count >= 5 {
            let rows = sessions.map { s -> (SlowdownProcess, Int) in (s, s.footprintKB + ownTree(s.pid).reduce(0) { $0 + $1.footprintKB }) }
                .sorted { $0.1 > $1.1 }
            let idle = rows.filter { $0.0.cpu < 2 }
            let idleKB = idle.reduce(0) { $0 + $1.1 }
            let totalKB = rows.reduce(0) { $0 + $1.1 }
            if idleKB >= 1_048_576 || memoryStrain != .none {
                found.append(SlowdownCulprit(
                    kind: .agentSessions, action: .review, name: tr("AI agent sessions"), launcher: nil, project: nil,
                    pids: rows.map(\.0.pid), identities: nil, app: nil, cpu: rows.reduce(0) { $0 + $1.0.cpu }, memoryKB: totalKB, freesKB: idleKB,
                    children: nil, elapsed: nil,
                    evidence: tr("%1$@ agent sessions are open using %2$@ with their tools; %3$@ of them are idle.",
                                 String(rows.count), gb(totalKB), String(idle.count)),
                    guidance: tr("Close the sessions you are done with in their terminal (each one also runs its own MCP servers). Thermo does not end agent sessions."),
                    command: "thermo agents", sessions: idle.prefix(20).map { s, kb in
                        "\(friendlyName(s)) · PID \(s.pid) · \(gb(kb))" + (tilde(s.cwd).map { " · " + $0 } ?? "")
                    }, score: score(cpu: 0, freesKB: idleKB, certain: false) * 0.15,
                    covered: idle.flatMap { [$0.0.pid] + ownTree($0.0.pid).map(\.pid) }))
            }
        }

        for i in found.indices where found[i].covered == nil && [.runaway, .orphan, .stuck, .heavyApp].contains(found[i].kind) {
            found[i].covered = found[i].pids
        }
        for i in found.indices where found[i].kind != .agentSessions {
            guard let p = found[i].pids.first.flatMap({ byPID[$0] }) else { continue }
            found[i].program = p.app.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
                ?? MachinePulse.programName(ProcessDetails(executable: p.executable, argv: p.argv, cwd: p.cwd), fallback: p.name)
        }
        /// What acting on `list` frees, each process counted once.
        func freed(_ list: [SlowdownCulprit]) -> Int {
            var seen = Set<Int32>(), kb = 0
            for c in list {
                guard let covered = c.covered else { kb += c.freesKB; continue }
                for pid in covered where seen.insert(pid).inserted { kb += byPID[pid]?.footprintKB ?? 0 }
            }
            return kb
        }
        let ranked = found.sorted { $0.score == $1.score ? $0.memoryKB > $1.memoryKB : $0.score > $1.score }
        // A culprit must matter: the top three that would make a difference.
        let main = Array(ranked.filter { $0.score >= 1 || $0.kind == .runaway || $0.kind == .orphan || $0.kind == .stuck }.prefix(3))
        let rest = ranked.filter { r in !main.contains { $0.id == r.id } }
        return SlowdownDiagnosis(sampled: sampled, system: system, memoryStrain: memoryStrain, cpuStrain: cpuStrain,
                                 headline: headline(system, memoryStrain, cpuStrain, main, frees: freed(main)), culprits: main, also: Array(rest.prefix(5)))
    }

    static func headline(_ s: SlowdownSystem, _ memory: SlowdownSystem.Strain, _ cpu: SlowdownSystem.Strain, _ culprits: [SlowdownCulprit], frees: Int) -> String {
        let swap = tr("swap %1$@ of %2$@ used", ByteFormat.string(Int64(s.swapUsed)), ByteFormat.string(Int64(s.swapTotal)))
        var first: String
        switch (memory, cpu) {
        case (.exhausted, _): first = tr("Memory is exhausted (%1$@).", swap)
        case (_, .exhausted): first = tr("The processors are overloaded (load %1$@ on %2$@ cores).", String(format: "%.0f", s.load1), String(s.cores))
        case (.tight, _): first = tr("Memory is tight (%1$@).", swap)
        case (_, .tight): first = tr("The processors are busy (load %1$@ on %2$@ cores).", String(format: "%.0f", s.load1), String(s.cores))
        default: first = tr("Nothing is slowing this Mac down right now.")
        }
        guard !culprits.isEmpty else { return first }
        let names = culprits.map(\.name).joined(separator: ", ")
        return MachinePulse.sentences(first, frees > 0
            ? tr("Main causes: %1$@ — acting on them frees about %2$@.", names, MemoryFormat.string(kibibytes: frees))
            : tr("Main causes: %1$@.", names))
    }
}

/// Live snapshots for `SlowdownDiagnosis`. Keeps the previous pass so CPU and disk writes are rates,
/// and how long each process (by identity) has stayed busy. Not thread-safe; use from one queue.
public final class SlowdownSampler {
    struct Previous { var at: UInt64; var cpu: UInt64; var written: UInt64?; var started: Date?; var childCPU: UInt64? }
    private var previous: [pid_t: Previous] = [:]
    private var busySince: [pid_t: (started: Date?, since: Date)] = [:]
    /// Short-lived children seen per parent: child PID → (command, last seen). Kept 10 minutes.
    private var young: [pid_t: [pid_t: (command: String, seen: Date)]] = [:]

    public init() {}

    /// First call measures over `window`; later calls measure since the previous call.
    public func sample(window: TimeInterval = 2, now: Date = Date()) -> [SlowdownProcess] {
        if previous.isEmpty {
            let first = ProcessTable.usage(uid: nil)
            remember(first, at: DispatchTime.now().uptimeNanoseconds)
            note(first, now: Date())
            // Poll the list meanwhile: a worker living two seconds is otherwise never seen.
            let end = Date().addingTimeInterval(max(0.2, window))
            while Date() < end {
                usleep(useconds_t(min(0.5, max(0.05, end.timeIntervalSinceNow)) * 1_000_000))
                note(ProcessTable.usage(uid: nil), now: Date())
            }
        }
        let usage = ProcessTable.usage(uid: nil)
        note(usage, now: now)
        let at = DispatchTime.now().uptimeNanoseconds
        let me = getuid()
        var out: [SlowdownProcess] = []
        out.reserveCapacity(usage.count)
        for u in usage {
            let old = previous[u.pid].flatMap { $0.started == u.started ? $0 : nil }
            let elapsed = old.map { Double(at &- $0.at) } ?? 0
            let cpu = old.flatMap { o -> Double? in
                guard elapsed > 0, u.cpuNanos >= o.cpu else { return nil }
                return Double(u.cpuNanos - o.cpu) / elapsed * 100
            } ?? 0
            let writes = old.flatMap { o -> Double? in
                guard elapsed > 0, let w = u.diskWrittenBytes, let ow = o.written, w >= ow else { return nil }
                return Double(w - ow) / (elapsed / 1e9)
            }
            let age = u.started.map { now.timeIntervalSince($0) } ?? 0
            let childCPU = old.flatMap { o -> Double? in
                guard elapsed > 0, let c = u.childCPUNanos, let oc = o.childCPU, c >= oc else { return nil }
                return Double(c - oc) / elapsed * 100
            }
            // Starts at the busy threshold, ends only below half of it: a spinning process dips between samples.
            let streak = busySince[u.pid].flatMap { $0.started == u.started ? $0 : nil }
            if cpu >= SlowdownDiagnosis.busyCPU, streak == nil {
                busySince[u.pid] = (u.started, now.addingTimeInterval(-elapsed / 1e9))
            } else if streak == nil || cpu < SlowdownDiagnosis.busyCPU / 2 { busySince[u.pid] = nil }
            // Details only for this user's processes; others give nothing useful anyway.
            let details = u.uid == me ? ProcessTable.details(u.pid) : ProcessDetails(executable: ProcessTable.pidPath(u.pid))
            out.append(SlowdownProcess(pid: u.pid, ppid: u.ppid, uid: u.uid, name: u.name, executable: details.executable,
                                       argv: details.argv, cwd: details.cwd, cpu: cpu,
                                       cpuLifetime: age > 0 && u.cpuAvailable ? Double(u.cpuNanos) / 1e9 / age * 100 : nil,
                                       busyFor: busySince[u.pid].map { now.timeIntervalSince($0.since) },
                                       footprintKB: u.memoryReading?.footprintKB ?? 0, residentKB: u.memoryReading?.residentKB,
                                       elapsed: age, writeBytesPerSecond: writes, started: u.started))
            out[out.count - 1].childCPU = childCPU
            if age > 0, let c = u.childCPUNanos { out[out.count - 1].childCPULifetime = Double(c) / 1e9 / age * 100 }
            if let kids = young[u.pid], !kids.isEmpty {
                var byCommand: [String: Int] = [:]
                for k in kids.values { byCommand[k.command, default: 0] += 1 }
                out[out.count - 1].youngChildren = byCommand
            }
        }
        let alive = Set(usage.map(\.pid))
        busySince = busySince.filter { alive.contains($0.key) }
        remember(usage, at: at)
        return out
    }

    private func remember(_ usage: [ProcessUsage], at: UInt64) {
        previous = Dictionary(usage.map { ($0.pid, Previous(at: at, cpu: $0.cpuNanos, written: $0.diskWrittenBytes, started: $0.started,
                                                             childCPU: $0.childCPUNanos)) },
                              uniquingKeysWith: { a, _ in a })
    }

    /// Records this user's children younger than 30 s under their parent; names are read once per PID.
    private func note(_ usage: [ProcessUsage], now: Date) {
        let me = getuid()
        for u in usage where u.uid == me && u.ppid > 1 {
            guard let started = u.started, now.timeIntervalSince(started) < 30, young[u.ppid]?[u.pid] == nil else {
                if young[u.ppid]?[u.pid] != nil { young[u.ppid]![u.pid]!.seen = now }
                continue
            }
            let d = ProcessTable.details(u.pid)
            let name = MachinePulse.programName(d, fallback: u.name)
            young[u.ppid, default: [:]][u.pid] = (name, now)
        }
        for (parent, kids) in young {
            let kept = kids.filter { now.timeIntervalSince($0.value.seen) <= 600 }
            young[parent] = kept.isEmpty ? nil : kept
        }
    }
}

/// The npm package a node-run tool comes from, read from its package.json (no network).
public struct PackageVersion: Codable, Sendable, Equatable {
    public var name: String
    public var version: String
    public init(name: String, version: String) { self.name = name; self.version = version }

    public static func installed(_ p: SlowdownProcess) -> PackageVersion? {
        guard let script = p.argv.dropFirst().first(where: { $0.hasPrefix("/") }) else { return nil }
        var url = URL(fileURLWithPath: script).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            let manifest = url.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: manifest),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["name"] as? String, let version = json["version"] as? String {
                return PackageVersion(name: name, version: version)
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}

/// Which of the user's launch agents runs an executable, so a daemon can be stopped the way it was started.
public enum LaunchAgentLabels {
    nonisolated(unsafe) private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    public static func label(forExecutable exe: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[exe] { return hit }
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let tool = (exe as NSString).lastPathComponent
        var found: String?
        for f in files where f.pathExtension == "plist" {
            guard let plist = NSDictionary(contentsOf: f), let label = plist["Label"] as? String else { continue }
            let args = (plist["ProgramArguments"] as? [String] ?? []) + [plist["Program"] as? String].compactMap { $0 }
            // Versioned installs move the binary; the same file name behind a stable launcher still counts.
            if args.contains(exe) || args.contains(where: { ($0 as NSString).lastPathComponent == tool }) { found = label; break }
        }
        cache[exe] = found
        return found
    }
}

/// Ending a culprit: recheck identity, SIGTERM, wait, SIGKILL if it ignored that, then re-measure.
public enum SlowdownFix {
    public enum Outcome: String, Codable, Sendable { case stopped, killed, stillRunning, changed, refused }

    public struct Result: Codable, Sendable {
        public var pid: Int32
        public var name: String
        public var outcome: Outcome
        public var freedKB: Int
        public var swapBefore: UInt64?
        public var swapAfter: UInt64?
        public var loadBefore: Double
        public var loadAfter: Double?
        public init(pid: Int32, name: String, outcome: Outcome, freedKB: Int, swapBefore: UInt64?, swapAfter: UInt64?, loadBefore: Double, loadAfter: Double?) {
            self.pid = pid; self.name = name; self.outcome = outcome; self.freedKB = freedKB
            self.swapBefore = swapBefore; self.swapAfter = swapAfter; self.loadBefore = loadBefore; self.loadAfter = loadAfter
        }
        public var summary: String {
            switch outcome {
            case .stopped: return tr("%1$@ (PID %2$@) stopped after being asked; about %3$@ freed.", name, String(pid), MemoryFormat.string(kibibytes: freedKB))
            case .killed: return tr("%1$@ (PID %2$@) ignored the request to stop and was forced to quit; about %3$@ freed.", name, String(pid), MemoryFormat.string(kibibytes: freedKB))
            case .stillRunning: return tr("%1$@ (PID %2$@) is still running.", name, String(pid))
            case .changed: return tr("PID %1$@ is no longer the process that was checked; nothing was sent.", String(pid))
            case .refused: return tr("%1$@ (PID %2$@) is a system process, an agent session, an app or Thermo; Thermo does not end it.", name, String(pid))
            }
        }
    }

    /// Whether `pid` may be ended from Thermo: the user's own command-line process, not system,
    /// not an agent session (closing those loses the conversation), not an app (apps quit), not Thermo.
    public static func endable(_ p: SlowdownProcess, me: Int32 = getpid()) -> Bool {
        p.pid != me && p.pid > 1 && !SlowdownDiagnosis.isSystem(p) && !SlowdownDiagnosis.isAgentSession(p)
            && !(p.executable?.contains(".app/Contents/MacOS/") == true && !SlowdownDiagnosis.isAppServer(p))
    }

    /// What refusing `p` says, without acting.
    public static func refusal(_ p: SlowdownProcess) -> Result {
        Result(pid: p.pid, name: SlowdownDiagnosis.friendlyName(p), outcome: .refused, freedKB: 0,
               swapBefore: nil, swapAfter: nil, loadBefore: 0, loadAfter: nil)
    }

    public static func end(_ p: SlowdownProcess, identity: ProcessIdentity?, grace: TimeInterval = 5,
                           record: Bool = true) -> Result {
        let before = SlowdownSystem.read()
        var result = Result(pid: p.pid, name: SlowdownDiagnosis.friendlyName(p), outcome: .refused, freedKB: 0,
                            swapBefore: before.swapUsed, swapAfter: nil, loadBefore: before.load1, loadAfter: nil)
        guard endable(p) else { return result }
        guard let identity, ProcessTable.identity(p.pid) == identity else { result.outcome = .changed; return finish(result, record) }
        func alive() -> Bool { ProcessTable.identity(p.pid) == identity }
        kill(p.pid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, alive() { usleep(200_000) }
        if alive() {
            kill(p.pid, SIGKILL)
            let hard = Date().addingTimeInterval(3)
            while Date() < hard, alive() { usleep(100_000) }
            result.outcome = alive() ? .stillRunning : .killed
        } else { result.outcome = .stopped }
        if result.outcome != .stillRunning { result.freedKB = p.footprintKB }
        // Let the kernel reclaim pages before re-measuring.
        Thread.sleep(forTimeInterval: 2)
        let after = SlowdownSystem.read()
        result.swapAfter = after.swapUsed; result.loadAfter = after.load1
        return finish(result, record)
    }

    static func finish(_ r: Result, _ record: Bool) -> Result {
        if record {
            let status = r.outcome == .stopped || r.outcome == .killed ? "done" : "failed"
            OperationJournal.record(OperationRecord(feature: "pulse", action: "end", subject: r.name,
                                                    items: [.init(target: "\(r.name) · PID \(r.pid)", bytes: Int64(r.freedKB) * 1024,
                                                                  status: status, detail: r.outcome.rawValue)]))
        }
        return r
    }
}
