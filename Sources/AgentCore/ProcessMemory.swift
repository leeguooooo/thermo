import Darwin
import Foundation

/// Footprint is a task ledger charge; RSS is resident mappings and includes shared pages.
/// They are different metrics: neither max(RSS, footprint) nor their difference is swap.
public struct ProcessMemoryReading: Equatable, Sendable {
    public var footprintKB: Int?
    public var residentKB: Int?
    public init(footprintKB: Int?, residentKB: Int?) {
        self.footprintKB = footprintKB; self.residentKB = residentKB
    }
}

extension ProcessTable {
    public static func memory(_ pid: pid_t) -> ProcessMemoryReading {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        } == 0
        if ok {
            return ProcessMemoryReading(footprintKB: Int(info.ri_phys_footprint / 1024),
                                        residentKB: Int(info.ri_resident_size / 1024))
        }
        var task = proc_taskinfo()
        let gotTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) == MemoryLayout<proc_taskinfo>.size
        return ProcessMemoryReading(footprintKB: nil, residentKB: gotTask ? Int(task.pti_resident_size / 1024) : nil)
    }
}
