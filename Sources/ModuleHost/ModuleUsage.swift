import Darwin
import Foundation

/// What one module process has cost so far. Counters since the process started; the kernel
/// subtracts two readings for a rate.
public struct ModuleUsage: Sendable, Equatable {
    public var pid: pid_t
    /// Memory charged to the process (what Activity Monitor shows).
    public var footprintBytes: UInt64
    public var cpuSeconds: Double
    public var energyJoules: Double

    public static func read(_ pid: pid_t) -> ModuleUsage? {
        var info = rusage_info_v6()
        let ok = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        } == 0
        guard ok else { return nil }
        var base = mach_timebase_info_data_t(); mach_timebase_info(&base)
        let ticks = info.ri_user_time &+ info.ri_system_time
        let nanos = Double(ticks) * Double(base.numer) / Double(max(1, base.denom))
        return ModuleUsage(pid: pid, footprintBytes: info.ri_phys_footprint, cpuSeconds: nanos / 1e9, energyJoules: Double(info.ri_energy_nj) / 1e9)
    }
}
