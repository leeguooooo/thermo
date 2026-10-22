import Darwin
import Foundation

/// Memory in use and free disk space, for the Overview gauges. Cheap: one host_statistics64 call
/// and one volume lookup.
enum SystemStats {
    struct Memory: Equatable, Sendable { var usedBytes: UInt64; var totalBytes: UInt64 }
    struct Disk: Equatable, Sendable { var freeBytes: Int64; var totalBytes: Int64 }

    /// "Used" as Activity Monitor counts it: app memory, wired and compressed.
    static func memory() -> Memory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        let used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return Memory(usedBytes: used, totalBytes: ProcessInfo.processInfo.physicalMemory)
    }

    static func disk() -> Disk? {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        guard let free = v?.volumeAvailableCapacityForImportantUsage, let total = v?.volumeTotalCapacity else { return nil }
        return Disk(freeBytes: free, totalBytes: Int64(total))
    }
}
