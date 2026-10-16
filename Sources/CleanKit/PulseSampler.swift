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
        func cpu(_ u: ProcessUsage) -> Double {
            let before = previous.cpu[u.pid] ?? u.cpuNanos  // new since the last pass: no share yet
            return u.cpuNanos >= before ? Double(u.cpuNanos - before) / window * 100 : 0
        }
        func candidate(_ u: ProcessUsage, details: ProcessDetails, owner: String?, started: Date?) -> MachinePulse.Candidate {
            .init(pid: u.pid, uid: u.uid, name: u.name, cpu: cpu(u), memoryKB: u.footprintKB,
                  details: details, owner: owner,
                  residentKB: u.memoryReading?.residentKB,
                  uptime: started.map { Date().timeIntervalSince($0) },
                  memoryMetric: u.memoryReading?.footprintKB == nil ? .unavailable : .footprint, ppid: u.ppid)
        }
        func checkedCandidate(_ u: ProcessUsage) -> MachinePulse.Candidate? {
            guard let started=u.started,let before=ProcessTable.identity(u.pid),before.uid == u.uid,before.started == started else { return nil }
            let details=ProcessTable.details(u.pid),association=owner(of:u,in:byPid)
            guard ProcessTable.identity(u.pid) == before,ProcessTable.parentPID(u.pid) == u.ppid else { return nil }
            return candidate(u,details:details,owner:association,started:started)
        }
        let mine = usage.filter { $0.uid == uid && $0.pid != me }  // Thermo is the observer, not a suspect
        // Resident size and start time only for candidates: a few calls, not one per process.
        for u in mine where cpu(u) > 0.5 || u.footprintKB > 200_000 {
            if let value=checkedCandidate(u) { candidates.append(value) }
        }
        let memory = MachinePulse.memoryLevel()
        var hogs = MachinePulse.group(candidates, byMemory: memory.isHigh, me: me)
        // Complete the rows that made the list: their small processes, and the same program in
        // other folders, so a row's totals and `elsewhere` cover every copy. Only processes that
        // could belong (same command name, or inside the same app) are looked at.
        let taken = Set(candidates.map(\.pid))
        let shownPids = Set(hogs.flatMap(\.pids))
        let commands = Set(usage.filter { shownPids.contains($0.pid) }.map(\.name))
        let apps = hogs.compactMap(\.app).map { $0 + "/" }
        var more: [MachinePulse.Candidate] = []
        for u in mine where !taken.contains(u.pid) {
            let inApp = !apps.isEmpty && { () -> Bool in
                guard let started=u.started,let identity=ProcessTable.identity(u.pid),identity.uid == u.uid,identity.started == started else { return false }
                return apps.contains { identity.executable.hasPrefix($0) }
            }()
            guard inApp || commands.contains(u.name) else { continue }
            if let value=checkedCandidate(u) { more.append(value) }
        }
        if !more.isEmpty { hogs = MachinePulse.group(candidates + more, byMemory: memory.isHigh, me: me) }
        var pulse = MachinePulse.measure(hogs: hogs)
        for index in pulse.hogs.indices {
            pulse.hogs[index].processIdentities = pulse.hogs[index].pids.compactMap(ProcessTable.identity)
        }
        return pulse
    }

    private func remember(_ usage: [ProcessUsage], at: UInt64) {
        last = (at, Dictionary(usage.map { ($0.pid, $0.cpuNanos) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Current ancestor evidence, never a claim about the original launcher.
    public func owner(of process: AgentProcess, in byPid: [pid_t: AgentProcess],
                      identity: (pid_t) -> ProcessIdentity? = ProcessTable.identity,
                      parent: (pid_t) -> pid_t? = ProcessTable.parentPID) -> String? {
        var current=process,seen=Set<pid_t>(),checked:[(AgentProcess,ProcessIdentity)]=[]
        for _ in 0..<16 {
            guard seen.insert(current.pid).inserted,let expected=current.sampledIdentity,
                  expected.pid == current.pid,expected.uid == current.uid,expected.executable == current.executable,
                  identity(current.pid) == expected,parent(current.pid) == current.ppid else { return nil }
            checked.append((current,expected))
            if current.pid != process.pid,let owner=Self.recognise(name:(expected.executable as NSString).lastPathComponent,executable:expected.executable) {
                guard checked.allSatisfy({ identity($0.0.pid) == $0.1 && parent($0.0.pid) == $0.0.ppid }) else { return nil }
                return owner
            }
            guard current.ppid > 1,let next=byPid[current.ppid] else { return nil }
            current=next
        }
        return nil
    }

    /// Cheap usage samples have start/UID evidence rather than full sampled identities.
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

    public static func recognise(name: String, executable exe: String) -> String? {
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
