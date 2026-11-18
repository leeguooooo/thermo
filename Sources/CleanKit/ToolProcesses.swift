import AgentCore
import Foundation

/// Tool processes that AI agents start and keep: MCP servers and the per-thread helpers of an agent
/// service. One session runs a handful; a shared service that never reaps them (codex app-server)
/// ends up with a full set per thread it ever served, which no "is this project in use" test catches
/// because the service serves every project at once. This inventory counts them per host and marks
/// the ones an emergency may end without closing any session or app.
public struct ToolProcessGroup: Sendable, Equatable, Identifiable, Encodable {
    public enum HostKind: String, Sendable, Encodable {
        /// A background service shared by many threads (codex app-server).
        case sharedService
        /// One agent session in a terminal.
        case session
        /// Whatever started it has exited.
        case none
    }

    /// One copy: the process the host started plus everything under it.
    public struct Copy: Sendable, Equatable, Encodable {
        public var pid: Int32
        /// Children first, so a wrapper is signalled after what it supervises.
        public var identities: [ProcessIdentity]
        public var memoryKB: Int
        public var elapsed: TimeInterval
        public var cpu: Double
        /// May be ended in an emergency: see `ToolProcesses.rescuable`.
        public var rescue: Bool
    }

    public var id: String { "\(hostPID ?? 0)|\(name)" }
    public var name: String
    public var hostKind: HostKind
    public var hostPID: Int32?
    public var hostName: String
    /// The session's folder; nil for a shared service, which has none of its own.
    public var hostProject: String?
    public var copies: [Copy]

    public var processes: Int { copies.reduce(0) { $0 + $1.identities.count } }
    public var memoryKB: Int { copies.reduce(0) { $0 + $1.memoryKB } }
    public var oldest: TimeInterval { copies.map(\.elapsed).max() ?? 0 }
    public var rescueCopies: [Copy] { copies.filter(\.rescue) }
    public var rescueKB: Int { rescueCopies.reduce(0) { $0 + $1.memoryKB } }
    public var identities: [ProcessIdentity] { copies.flatMap(\.identities) }
}

public enum ToolProcesses {
    /// A copy held by a shared service counts as left behind once it is this old and not working.
    public static let rescueAge: TimeInterval = 3600
    /// Helpers an agent service starts per thread that are not MCP servers by name.
    static let serviceHelpers: Set<String> = ["node_repl", "skycomputeruseclient"]
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "login"]

    public static func isTool(_ p: SlowdownProcess, hostIsService: Bool) -> Bool {
        guard p.app == nil, !SlowdownDiagnosis.isAgentSession(p), !SlowdownDiagnosis.isAppServer(p) else { return false }
        let name = p.name.lowercased()
        guard !shells.contains(name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))) else { return false }
        if SlowdownDiagnosis.isMCP(p) { return true }
        // "node …/mcp-feedback-channel.mjs": the script's own name says it.
        if p.argv.dropFirst().prefix(4).contains(where: { ($0 as NSString).lastPathComponent.lowercased().contains("mcp") }) { return true }
        return hostIsService && serviceHelpers.contains(name)
    }

    /// An emergency may end it: nobody can be waiting on it right now, and no session or app closes.
    /// Left behind by a starter that exited, or held for over an hour by a shared service while idle.
    static func rescuable(host: ToolProcessGroup.HostKind, elapsed: TimeInterval, cpu: Double) -> Bool {
        guard cpu < 2 else { return false }
        switch host {
        case .none: return true
        case .sharedService: return elapsed >= rescueAge
        case .session: return false
        }
    }

    public static func inventory(_ processes: [SlowdownProcess], me: Int32 = getpid(),
                                 starterExited: (SlowdownProcess) -> Bool = { ProcessTable.starterExited(pid: $0.pid, ppid: $0.ppid, pgid: getpgid($0.pid)) },
                                 identity: (SlowdownProcess) -> ProcessIdentity? = { p in
                                     guard let executable = p.executable, let started = p.started else { return nil }
                                     return ProcessIdentity(pid: p.pid, uid: p.uid, started: started, executable: executable)
                                 }) -> [ToolProcessGroup] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var children: [Int32: [SlowdownProcess]] = [:]
        for p in processes { children[p.ppid, default: []].append(p) }
        // Whatever leads up to this process (the CLI's own shell and session) is never a target.
        var mine: Set<Int32> = []
        var cursor = me
        while cursor > 1, mine.insert(cursor).inserted, let p = byPID[cursor] { cursor = p.ppid }

        func tree(_ root: SlowdownProcess) -> [SlowdownProcess] {
            var out: [SlowdownProcess] = [], seen: Set<Int32> = [root.pid]
            func walk(_ p: SlowdownProcess) {
                for c in children[p.pid] ?? [] where seen.insert(c.pid).inserted && !SlowdownDiagnosis.isAgentSession(c) && !SlowdownDiagnosis.isAppServer(c) { walk(c) }
                out.append(p)
            }
            walk(root)
            return out
        }

        var groups: [String: ToolProcessGroup] = [:]
        for p in processes where p.pid > 1 && p.uid == getuid() {
            let parent = byPID[p.ppid]
            let kind: ToolProcessGroup.HostKind
            if let parent, SlowdownDiagnosis.isAppServer(parent) { kind = .sharedService }
            else if let parent, SlowdownDiagnosis.isAgentSession(parent) { kind = .session }
            else if p.ppid == 1 { kind = .none }
            else { continue }
            guard isTool(p, hostIsService: kind == .sharedService) else { continue }
            // Under launchd on purpose (a login item, a detached daemon) is a service, not a leftover.
            if kind == .none, !starterExited(p) { continue }
            let members = tree(p)
            guard mine.isDisjoint(with: members.map(\.pid)), parent.map({ !mine.contains($0.pid) }) ?? true else { continue }
            // Every process of the copy must be one Thermo may end, and readable well enough to recheck.
            let ids = members.compactMap(identity)
            guard ids.count == members.count, members.allSatisfy({ SlowdownFix.endable($0, me: me) }) else { continue }
            let cpu = members.reduce(0) { $0 + $1.cpu }
            let copy = ToolProcessGroup.Copy(pid: p.pid, identities: ids, memoryKB: members.reduce(0) { $0 + $1.footprintKB },
                                             elapsed: p.elapsed, cpu: cpu, rescue: rescuable(host: kind, elapsed: p.elapsed, cpu: cpu))
            let name = toolName(p)
            let key = "\(kind == .none ? 0 : p.ppid)|\(name)"
            if groups[key] == nil {
                groups[key] = ToolProcessGroup(name: name, hostKind: kind, hostPID: kind == .none ? nil : p.ppid,
                                               hostName: parent.map(SlowdownDiagnosis.friendlyName) ?? "",
                                               hostProject: kind == .session ? parent?.cwd : nil, copies: [])
            }
            groups[key]?.copies.append(copy)
        }
        return groups.values.map { g in var g = g; g.copies.sort { $0.memoryKB > $1.memoryKB }; return g }
            .sorted { a, b in a.memoryKB != b.memoryKB ? a.memoryKB > b.memoryKB : a.id < b.id }
    }

    /// "codegraph", not "node": the program the copy runs, without the "MCP server" suffix a list of tools does not need.
    static func toolName(_ p: SlowdownProcess) -> String {
        if serviceHelpers.contains(p.name.lowercased()) { return p.name }
        return MachinePulse.programName(ProcessDetails(executable: p.executable, argv: p.argv, cwd: p.cwd), fallback: p.name)
    }

    /// One line per tool and kind of host: "codegraph ×21 in 21 sessions" answers which tool it is.
    public struct Summary: Sendable, Equatable, Identifiable, Encodable {
        public var id: String { "\(hostKind.rawValue)|\(name)" }
        public var name: String
        public var hostKind: ToolProcessGroup.HostKind
        public var groups: [ToolProcessGroup]
        public var hosts: Int { Set(groups.compactMap(\.hostPID)).count }
        public var copies: Int { groups.reduce(0) { $0 + $1.copies.count } }
        public var processes: Int { groups.reduce(0) { $0 + $1.processes } }
        public var memoryKB: Int { groups.reduce(0) { $0 + $1.memoryKB } }
        public var oldest: TimeInterval { groups.map(\.oldest).max() ?? 0 }
        public var rescueCopies: Int { groups.reduce(0) { $0 + $1.rescueCopies.count } }
        public var rescueKB: Int { groups.reduce(0) { $0 + $1.rescueKB } }
        public var identities: [ProcessIdentity] { groups.flatMap(\.identities) }
        public var hostName: String { groups.first?.hostName ?? "" }
    }

    public static func summary(_ groups: [ToolProcessGroup]) -> [Summary] {
        var out: [String: Summary] = [:]
        for g in groups {
            let key = "\(g.hostKind.rawValue)|\(g.name)"
            out[key, default: Summary(name: g.name, hostKind: g.hostKind, groups: [])].groups.append(g)
        }
        return out.values.sorted { a, b in a.memoryKB != b.memoryKB ? a.memoryKB > b.memoryKB : a.id < b.id }
    }

    public static func rescueIdentities(_ groups: [ToolProcessGroup]) -> [ProcessIdentity] {
        groups.flatMap { $0.rescueCopies.flatMap(\.identities) }
    }

    public struct Outcome: Sendable, Encodable {
        public var asked = 0
        public var ended = 0
        public var forced = 0
        public var stillRunning = 0
        /// Changed, exited or protected between the reading and the signal: nothing was sent.
        public var skipped = 0
        public var freedKB = 0
        public var swapBefore: UInt64?
        public var swapAfter: UInt64?
        public init(swapBefore: UInt64? = nil) { self.swapBefore = swapBefore }

        public var summary: String {
            var text = asked == 0 ? tr("Nothing was ended: none of the processes still qualified when checked again.")
                : tr("Ended %1$@ of %2$@ processes; about %3$@ freed.", String(ended), String(asked), MemoryFormat.string(kibibytes: freedKB))
            if stillRunning > 0 { text = MachinePulse.sentences(text, tr("%1$@ are still running.", String(stillRunning))) }
            if let before = swapBefore, let after = swapAfter, asked > 0 {
                text = MachinePulse.sentences(text, tr("Swap used: %1$@ → %2$@.", MemoryFormat.string(bytes: before), MemoryFormat.string(bytes: after)))
            }
            return text
        }
    }

    /// Ends all of them together: one SIGTERM round, one wait, then SIGKILL for what ignored it.
    /// Each signal goes through the gate, so a reused PID, an app or an agent session is never hit.
    public static func end(_ identities: [ProcessIdentity], memoryKB: [Int32: Int] = [:], subject: String, grace: TimeInterval = 5,
                           record: Bool = true, journalHome: String = NSHomeDirectory(),
                           signal: (Int32, Int32) -> Bool = { kill($0, $1) == 0 }) -> Outcome {
        var out = Outcome(swapBefore: SlowdownSystem.read().swapUsed)
        var asked: [ProcessIdentity] = []
        for identity in identities {
            if ProcessActionGate.attempt(identity, allowApplication: false, request: { signal($0.pid, SIGTERM) }) == .requested { asked.append(identity) }
            else { out.skipped += 1 }
        }
        out.asked = asked.count
        func alive() -> [ProcessIdentity] { asked.filter { ProcessTable.identity($0.pid) == $0 } }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, !alive().isEmpty { usleep(200_000) }
        let stubborn = alive()
        for identity in stubborn { _ = ProcessActionGate.attempt(identity, allowApplication: false, request: { signal($0.pid, SIGKILL) }) }
        if !stubborn.isEmpty {
            let hard = Date().addingTimeInterval(3)
            while Date() < hard, !alive().isEmpty { usleep(100_000) }
        }
        let left = Set(alive().map(\.pid))
        out.stillRunning = left.count
        out.ended = asked.count - left.count
        out.forced = stubborn.filter { !left.contains($0.pid) }.count
        out.freedKB = asked.filter { !left.contains($0.pid) }.reduce(0) { $0 + (memoryKB[$1.pid] ?? 0) }
        if out.asked > 0 { Thread.sleep(forTimeInterval: 1) }
        out.swapAfter = SlowdownSystem.read().swapUsed
        if record, out.asked > 0 {
            OperationJournal.record(OperationRecord(feature: "memory", action: "tools", subject: subject, items: [
                .init(target: "\(subject) · \(out.asked) PIDs", bytes: Int64(out.freedKB) * 1024,
                      status: out.stillRunning == 0 ? "done" : "failed",
                      detail: "ended \(out.ended), forced \(out.forced), stillRunning \(out.stillRunning), skipped \(out.skipped)")]), home: journalHome)
        }
        return out
    }
}
