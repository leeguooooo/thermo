import AgentCore
import Darwin
import Foundation

/// Keeps the previous CPU times so each refresh is one cheap pass over the process list:
/// CPU % comes from the difference between two passes, and paths, arguments and owners are read
/// only for the handful of processes that could make the list. Not thread-safe; use from one queue.
public final class PulseSampler {
    private var last: (at: UInt64, cpu: [pid_t: UInt64])?

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
                                    residentKB: u.memoryReading?.residentKB,
                                    uptime: ProcessTable.started(u.pid).map { Date().timeIntervalSince($0) },
                                    memoryMetric: u.memoryReading?.footprintKB == nil ? .unavailable : .footprint))
        }
        let memory = MachinePulse.memoryLevel()
        var pulse = MachinePulse.measure(hogs: MachinePulse.group(candidates, byMemory: memory.isHigh, me: getpid()))
        for index in pulse.hogs.indices {
            pulse.hogs[index].processIdentities = pulse.hogs[index].pids.compactMap(ProcessTable.identity)
        }
        return pulse
    }

    private func remember(_ usage: [ProcessUsage], at: UInt64) {
        last = (at, Dictionary(usage.map { ($0.pid, $0.cpuNanos) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Current ancestor evidence, never a claim about the original launcher.
    func owner(of u: ProcessUsage, in byPid: [pid_t: ProcessUsage],
               identity: (pid_t) -> ProcessIdentity? = ProcessTable.identity,
               parent: (pid_t) -> pid_t? = ProcessTable.parentPID) -> String? {
        var current = u, seen = Set<pid_t>(), checked: [(ProcessUsage, ProcessIdentity)] = []
        for _ in 0..<16 {
            guard seen.insert(current.pid).inserted, let started = current.started,
                  let actual = identity(current.pid), actual.uid == current.uid, actual.started == started,
                  parent(current.pid) == current.ppid else { return nil }
            checked.append((current, actual))
            if current.pid != u.pid, let owner = Self.recognise(name: (actual.executable as NSString).lastPathComponent, executable: actual.executable) {
                guard checked.allSatisfy({ identity($0.0.pid) == $0.1 && parent($0.0.pid) == $0.0.ppid }) else { return nil }
                return owner
            }
            guard current.ppid > 1, let next = byPid[current.ppid] else { return nil }
            current = next
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
