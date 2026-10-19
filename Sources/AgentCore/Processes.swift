import Darwin
import Foundation

/// One running process, read directly from the kernel (no `ps` subprocess).
public struct AgentProcess: Equatable, Sendable {
    public var pid: pid_t
    public var ppid: pid_t
    public var uid: uid_t
    /// Short command name (`p_comm`, at most 16 bytes).
    public var name: String
    /// Executable from proc_pidpath; when the binary was deleted, an absolute argv[0] instead.
    public var executable: String?
    /// True when proc_pidpath failed and `executable` came from argv[0].
    public var executableFromArgv: Bool
    /// Full argument vector (empty for other users' processes).
    public var argv: [String]
    public var cwd: String?
    /// Decayed CPU average like `ps -o pcpu` (sum over threads; 100 = one core).
    public var cpu: Double
    public var rssKB: Int
    /// Memory as Activity Monitor counts it (phys_footprint: includes compressed and swapped pages).
    public var footprintKB: Int = 0
    public var elapsed: TimeInterval
    /// Nil only for legacy/manual fixtures. Live reads preserve unavailable counters.
    public var memoryReading: ProcessMemoryReading? = nil
    public var sampledIdentity: ProcessIdentity? = nil

    public init(pid: pid_t, ppid: pid_t = 1, uid: uid_t = getuid(), name: String, executable: String? = nil,
                executableFromArgv: Bool = false, argv: [String] = [], cwd: String? = nil, cpu: Double = 0,
                rssKB: Int = 0, footprintKB: Int = 0, elapsed: TimeInterval = 0) {
        self.pid = pid; self.ppid = ppid; self.uid = uid; self.name = name; self.executable = executable
        self.executableFromArgv = executableFromArgv; self.argv = argv; self.cwd = cwd; self.cpu = cpu
        self.rssKB = rssKB; self.footprintKB = footprintKB; self.elapsed = elapsed
    }

    /// The command line joined with spaces, as `ps -o args` prints it.
    public var args: String { argv.isEmpty ? name : argv.joined(separator: " ") }
}

/// A snapshot of running processes. Build one by hand in tests with `init(entries:)`.
public struct ProcessTable: Sendable {
    public let entries: [AgentProcess]
    public let available: Bool
    /// False if rows were dropped because process identities changed during enumeration.
    public let inventoryComplete: Bool
    public let includesAllUsers: Bool

    public init(entries: [AgentProcess], available: Bool = true, inventoryComplete: Bool = true, includesAllUsers: Bool = true) {
        self.entries=entries;self.available=available;self.inventoryComplete=available && inventoryComplete;self.includesAllUsers=includesAllUsers
    }

    public struct Options: Sendable {
        /// Only processes of this user (nil = everyone; details of others' processes are mostly unavailable).
        public var uid: uid_t? = getuid()
        /// Per-thread CPU usage costs one call per thread; skip it when not needed.
        public var cpu = true
        /// Restrict argv/cwd/memory detail reads while retaining other users in the parent graph.
        public var detailsUID: uid_t? = nil
        public init(uid: uid_t? = getuid(), cpu: Bool = true, detailsUID: uid_t? = nil) {
            self.uid = uid; self.cpu = cpu; self.detailsUID = detailsUID
        }
    }

    /// Cancellation is checked between processes; it cannot interrupt a kernel call.
    /// A cancelled inventory is unavailable, so callers cannot treat its prefix as complete.
    public static func current(_ options: Options = Options(), cancelled: () -> Bool = { false }) -> ProcessTable {
        func cancelledTable() -> ProcessTable {
            ProcessTable(entries: [], available: false, inventoryComplete: false, includesAllUsers: options.uid == nil)
        }
        guard !cancelled() else { return cancelledTable() }
        var mib: [Int32] = options.uid.map { [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: $0)] }
            ?? [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return ProcessTable(entries: [], available: false) }
        size += size / 8
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return ProcessTable(entries: [], available: false) }
        let count = size / MemoryLayout<kinfo_proc>.stride
        let now = Date().timeIntervalSince1970
        var out: [AgentProcess] = []
        var inventoryComplete = true
        out.reserveCapacity(count)
        for k in procs.prefix(count) {
            guard !cancelled() else { return cancelledTable() }
            let pid = k.kp_proc.p_pid
            guard pid > 0 else { continue }
            let name = withUnsafeBytes(of: k.kp_proc.p_comm) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            let start = k.kp_proc.p_un.__p_starttime
            let started = TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1e6
            let inspectDetails = options.detailsUID.map { $0 == k.kp_eproc.e_ucred.cr_uid } ?? true
            let argv = inspectDetails ? arguments(pid) : []
            var exe = pidPath(pid)
            var fromArgv = false
            if exe == nil, let first = argv.first, first.hasPrefix("/") { exe = first; fromArgv = true }
            // Reuse the start/UID from the process-list snapshot and the path already read.
            // One identity recheck after reading avoids attaching an old measurement to a reused PID.
            let before: ProcessIdentity? = started > 0 && !fromArgv ? exe.map {
                ProcessIdentity(pid: pid, uid: k.kp_eproc.e_ucred.cr_uid,
                                started: Date(timeIntervalSince1970: started), executable: $0)
            } : nil
            let reading = inspectDetails ? memory(pid) : ProcessMemoryReading(footprintKB: nil, residentKB: nil)
            var process = AgentProcess(pid: pid, ppid: k.kp_eproc.e_ppid, uid: k.kp_eproc.e_ucred.cr_uid, name: name,
                                    executable: exe, executableFromArgv: fromArgv, argv: argv, cwd: inspectDetails ? cwd(pid) : nil,
                                    cpu: options.cpu ? cpuUsage(pid) : 0, rssKB: reading.residentKB ?? 0,
                                    footprintKB: reading.footprintKB ?? 0, elapsed: started > 0 ? max(0, now - started) : 0)
            if let before, before != identity(pid) { inventoryComplete=false;continue }
            process.sampledIdentity = before
            process.memoryReading = reading
            out.append(process)
        }
        guard !cancelled() else { return cancelledTable() }
        let expectsSelf = options.uid == nil || options.uid == getuid()
        return ProcessTable(entries: out, available: !expectsSelf || out.contains { $0.pid == getpid() },
                            inventoryComplete:inventoryComplete,includesAllUsers:options.uid == nil)
    }

    // MARK: per-process readers (each returns nil/0 when the kernel says no)

    public static func pidPath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    static func cwd(_ pid: pid_t) -> String? {
        workingDirectory(pid)
    }

    /// Current kernel-observed cwd, unavailable when the process cannot be read.
    public static func workingDirectory(_ pid: pid_t) -> String? {
        var vp = proc_vnodepathinfo()
        guard pid > 0, proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vp, Int32(MemoryLayout<proc_vnodepathinfo>.size)) == MemoryLayout<proc_vnodepathinfo>.size else { return nil }
        let s = withUnsafeBytes(of: vp.pvi_cdir.vip_path) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        return s.isEmpty ? nil : s
    }

    /// When the process started, from its BSD info (nil when the kernel won't say).
    public static func started(_ pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
              info.pbi_start_tvsec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
    }

    /// Legacy convenience reader. New diagnostics use `memory` to retain unavailable values.
    public static func residentKB(_ pid: pid_t) -> Int { memory(pid).residentKB ?? 0 }

    /// Sum of the scheduler's decayed per-thread usage, the figure `ps` shows as %CPU.
    static func cpuUsage(_ pid: pid_t) -> Double {
        var ids = [UInt64](repeating: 0, count: 512)
        let n = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, &ids, Int32(ids.count * MemoryLayout<UInt64>.size))
        guard n > 0 else { return 0 }
        var total = 0.0
        for id in ids.prefix(Int(n) / MemoryLayout<UInt64>.size) {
            var t = proc_threadinfo()
            if proc_pidinfo(pid, PROC_PIDTHREADINFO, id, &t, Int32(MemoryLayout<proc_threadinfo>.size)) > 0 {
                total += Double(t.pth_cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        return total
    }

    /// argv from KERN_PROCARGS2: `argc`, the exec path, padding NULs, then argc NUL-terminated strings.
    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }      // exec path
        while i < size && buf[i] == 0 { i += 1 }      // padding
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    // MARK: queries

    /// The name of the first of `names` (process name or app bundle name) that is running.
    public func running(_ names: [String]) -> String? {
        for n in names {
            let lower = n.lowercased()
            if let e = entries.first(where: {
                let exe = ($0.executable ?? "").lowercased()
                // A helper another app launches from inside the bundle (Claude.app's Chrome native
                // host) does not mean the app is open.
                if exe.contains("/\(lower).app/") { return !exe.contains("/\(lower).app/contents/helpers/") }
                // A command-line program matches only its exact name: the `claude` CLI is not the
                // Claude app, `go` and `pnpm` still match themselves.
                if !exe.isEmpty && !exe.contains(".app/") { return $0.name == n }
                return $0.name.lowercased() == lower
            }) {
                return (e.executable ?? "").contains(".app/") ? n : e.name
            }
        }
        return nil
    }

    /// Command names of AI coding agents.
    public static let agentNames = ["claude", "codex", "gemini", "opencode", "aider", "amp", "cursor-agent", "qwen", "goose", "crush"]

    /// Working directories of processes that look like AI coding agents.
    public func agentDirectories() -> Set<String> {
        var dirs = Set<String>()
        for e in entries {
            let n = e.name.lowercased()
            let p = (e.executable ?? "").lowercased()
            let first = ((e.argv.first ?? "") as NSString).lastPathComponent.lowercased()
            let isAgent = Self.agentNames.contains(n) || Self.agentNames.contains(first)
                || Self.agentNames.contains { p.hasSuffix("/" + $0) || p.contains("/" + $0 + "/") }
            if isAgent, let c = e.cwd, !c.isEmpty, c != "/" { dirs.insert(c) }
        }
        return dirs
    }
}

/// A PID alone is not an identity: macOS reuses it after a process exits.
public struct ProcessIdentity: Codable, Sendable, Equatable {
    public var pid: Int32
    public var uid: UInt32
    public var started: Date
    public var executable: String

    public init(pid: Int32, uid: UInt32, started: Date, executable: String) {
        self.pid = pid; self.uid = uid; self.started = started; self.executable = executable
    }
}

/// Public kinfo metadata, kept separate from the ordinary process inventory so
/// a diagnostic fallback cannot change cleanup's inventory-completeness rules.
struct RootProcessSnapshot: Equatable {
    var pid: Int32
    var ppid: Int32
    var uid: UInt32
    var name: String
    var started: Date
}

extension ProcessTable {
    /// Some root processes deny PROC_PIDTBSDINFO while allowing public sysctl
    /// metadata and their executable path. Never reads argv, cwd, FDs or memory.
    public static func rootProcess(_ pid: Int32) -> AgentProcess? {
        rootProcess(pid, snapshot: { rootSnapshot(pid) }, path: pidPath)
    }

    static func rootProcess(_ pid: Int32, snapshot: () -> RootProcessSnapshot?,
                            path: (Int32) -> String?) -> AgentProcess? {
        guard pid > 0, let before = snapshot(), before.pid == pid, before.uid == 0,
              before.started.timeIntervalSince1970.isFinite, before.started.timeIntervalSince1970 > 0,
              let executable = path(pid), executable.hasPrefix("/"), snapshot() == before else { return nil }
        var row = AgentProcess(pid: pid, ppid: before.ppid, uid: 0, name: before.name, executable: executable)
        row.sampledIdentity = .init(pid: pid, uid: 0, started: before.started, executable: executable)
        row.memoryReading = .init(footprintKB: nil, residentKB: nil)
        return row
    }

    private static func rootSnapshot(_ pid: Int32) -> RootProcessSnapshot? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var value = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &value, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride, value.kp_proc.p_pid == pid,
              value.kp_eproc.e_ucred.cr_uid == 0 else { return nil }
        let start = value.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0, start.tv_usec >= 0, start.tv_usec < 1_000_000 else { return nil }
        let name = withUnsafeBytes(of: value.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return .init(pid: pid, ppid: value.kp_eproc.e_ppid, uid: 0, name: name,
                     started: Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1e6))
    }

    public static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        return Int32(bitPattern: info.pbi_ppid)
    }

    public static func identity(_ pid: pid_t) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
              info.pbi_start_tvsec > 0, let executable = pidPath(pid) else { return nil }
        let start = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
        guard started(pid) == start else { return nil }
        return ProcessIdentity(pid: pid, uid: info.pbi_uid, started: start, executable: executable)
    }
}
