import Darwin
import Foundation
import IOKit

/// What the menu bar panel needs every two seconds, without the per-process walk `ComputeSampler`
/// does: whole-machine CPU ticks and each GPU's own utilization counter.
public enum QuickLoad {
    public static func cpuTicks() -> [UInt32]? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self(); defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
    }

    /// Busy share of all cores between two readings, 0...100.
    public static func cpuPercent(_ current: [UInt32], since previous: [UInt32]) -> Double? {
        ComputeSampler.hostRate(current, previous)
    }

    /// The busiest GPU's utilization, 0...100; nil when the driver does not report it.
    public static func gpuPercent() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            guard let stats = IORegistryEntryCreateCFProperty(device, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            if let p = ComputeSampler.percent(stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) { best = max(best ?? 0, p) }
        }
        return best
    }
}
