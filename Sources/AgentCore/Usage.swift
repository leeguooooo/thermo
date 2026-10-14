import Darwin
import Foundation

/// The cheap per-process numbers for "who is busy": one sysctl for the list, then one
/// `proc_pid_rusage` per process (CPU time and memory together). No argv, paths or per-thread
/// calls; fetch those with `ProcessTable.details` for the few processes worth naming.
public struct ProcessUsage: Equatable, Sendable {
    public var pid: pid_t
    public var ppid: pid_t
    public var uid: uid_t
    /// Short command name (`p_comm`).
    public var name: String
    /// CPU time used so far, user + system, in nanoseconds.
    public var cpuNanos: UInt64
    /// Memory as Activity Monitor counts it (phys_footprint), in KB.
    public var footprintKB: Int
    public var memoryReading: ProcessMemoryReading? = nil

    public init(pid: pid_t, ppid: pid_t = 1, uid: uid_t = getuid(), name: String, cpuNanos: UInt64 = 0, footprintKB: Int = 0) {
        self.pid = pid; self.ppid = ppid; self.uid = uid; self.name = name; self.cpuNanos = cpuNanos; self.footprintKB = footprintKB
    }
}

/// What it takes to name a process: where it runs from and what it was started with.
public struct ProcessDetails: Equatable, Sendable {
    public var executable: String?
    public var argv: [String]
    public var cwd: String?

    public init(executable: String? = nil, argv: [String] = [], cwd: String? = nil) {
        self.executable = executable; self.argv = argv; self.cwd = cwd
    }
}

extension ProcessTable {
    /// Every process of `uid` (nil = all) with its CPU time and memory. Other users' processes
    /// come back with zeros where the kernel refuses.
    public static func usage(uid: uid_t? = getuid()) -> [ProcessUsage] {
        var mib: [Int32] = uid.map { [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: $0)] } ?? [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }
        size += size / 8
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        let (numer, denom) = timebase
        var out: [ProcessUsage] = []
        out.reserveCapacity(count)
        for k in procs.prefix(count) {
            let pid = k.kp_proc.p_pid
            guard pid > 0 else { continue }
            let name = withUnsafeBytes(of: k.kp_proc.p_comm) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            } == 0
            // rusage times are mach ticks (nanoseconds on Intel, not on Apple Silicon).
            let ticks = ok ? info.ri_user_time &+ info.ri_system_time : 0
            var process = ProcessUsage(pid: pid, ppid: k.kp_eproc.e_ppid, uid: k.kp_eproc.e_ucred.cr_uid, name: name,
                                    cpuNanos: ticks &* numer / denom, footprintKB: ok ? Int(info.ri_phys_footprint / 1024) : 0)
            process.memoryReading = ok ? ProcessMemoryReading(footprintKB: process.footprintKB, residentKB: Int(info.ri_resident_size / 1024))
                : ProcessMemoryReading(footprintKB: nil, residentKB: nil)
            out.append(process)
        }
        return out
    }

    public static func details(_ pid: pid_t) -> ProcessDetails {
        let argv = arguments(pid)
        var exe = pidPath(pid)
        if exe == nil, let first = argv.first, first.hasPrefix("/") { exe = first }
        return ProcessDetails(executable: exe, argv: argv, cwd: cwd(pid))
    }

    static let timebase: (UInt64, UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(max(1, tb.numer)), UInt64(max(1, tb.denom)))
    }()
}
