import AgentCore
import Darwin
import Foundation

/// Keeps the previous CPU times so each refresh is one cheap pass over the process list:
/// CPU % comes from the difference between two passes, and paths, arguments and owners are read
/// only for the handful of processes that could make the list. Not thread-safe; use from one queue.
public final class PulseSampler {
    private var last: (at: UInt64, cpu: [pid_t: UInt64])?
    /// Executable per pid, for the parent-chain walk; dropped when the pid's name changes.
    private var exeCache: [pid_t: (name: String, exe: String)] = [:]

    public init() {}

    public func sample() -> MachinePulse {
        // Everyone's processes, so the parent chain can pass root-owned `login` on its way to the
        // terminal; only this user's processes become candidates.
        var usage = ProcessTable.usage(uid: nil)
        var now = DispatchTime.now().uptimeNanoseconds
        if last == nil {
            // The first pass has nothing to compare with: measure over a short window.
            remember(usage, at: now)
            usleep(400_000)
            usage = ProcessTable.usage(uid: nil)
            now = DispatchTime.now().uptimeNanoseconds
        }
        let previous = last!
        let window = Double(max(1, now - previous.at))
        remember(usage, at: now)

        let byPid = Dictionary(usage.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var candidates: [MachinePulse.Candidate] = []
        let me = getpid(), uid = getuid()
        for u in usage where u.uid == uid && u.pid != me {  // Thermo is the observer, not a suspect
            let before = previous.cpu[u.pid] ?? u.cpuNanos  // new since the last pass: no share yet
            let cpu = u.cpuNanos >= before ? Double(u.cpuNanos - before) / window * 100 : 0
            guard cpu > 0.5 || u.footprintKB > 200_000 else { continue }
            // Resident size and start time only for candidates: a few calls, not one per process.
            candidates.append(.init(pid: u.pid, uid: u.uid, name: u.name, cpu: cpu, memoryKB: u.footprintKB,
                                    details: ProcessTable.details(u.pid), owner: owner(of: u, in: byPid),
                                    residentKB: ProcessTable.residentKB(u.pid),
                                    uptime: ProcessTable.started(u.pid).map { Date().timeIntervalSince($0) }))
        }
        let memory = MachinePulse.memoryLevel()
        return MachinePulse.measure(hogs: MachinePulse.group(candidates, byMemory: memory != .normal, me: getpid()))
    }

    private func remember(_ usage: [ProcessUsage], at: UInt64) {
        last = (at, Dictionary(usage.map { ($0.pid, $0.cpuNanos) }, uniquingKeysWith: { a, _ in a }))
        let alive = Set(usage.map(\.pid))
        exeCache = exeCache.filter { alive.contains($0.key) }
    }

    private func executable(_ u: ProcessUsage) -> String {
        if let c = exeCache[u.pid], c.name == u.name { return c.exe }
        let exe = ProcessTable.pidPath(u.pid) ?? ""
        exeCache[u.pid] = (u.name, exe)
        return exe
    }

    /// The first agent, terminal or editor above a process: who to ask about it.
    func owner(of u: ProcessUsage, in byPid: [pid_t: ProcessUsage]) -> String? {
        var pid = u.ppid
        for _ in 0..<16 {
            guard pid > 1, let p = byPid[pid] else { return nil }
            let exe = executable(p)
            if let o = Self.recognise(name: p.name, executable: exe) { return o }
            pid = p.ppid
        }
        return nil
    }

    static func recognise(name: String, executable exe: String) -> String? {
        let base = (exe as NSString).lastPathComponent.lowercased()
        if exe.contains("/claude/versions/") || base == "claude" { return "Claude Code" }
        if base == "codex" || exe.contains("/codex/") && !exe.contains(".app/") { return "Codex" }
        if let agent = ProcessTable.agentNames.first(where: { $0 == base || $0 == name.lowercased() }) { return agent }
        if let r = exe.range(of: ".app/") {
            // The outermost app: VS Code's helpers belong to "Visual Studio Code".
            let app = String(exe[..<r.lowerBound])
            return ((app as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return nil
    }
}
