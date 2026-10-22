import AgentCore
import Darwin
import Foundation
import IOKit

public struct GPUDeviceActivity: Codable, Identifiable, Sendable {
    public var id: UInt64
    public var name: String
    public var percent: Double?
}

struct GPUClientCounter: Equatable {
    var id: UInt64
    var pid: pid_t
    var counters: [UInt64]
}

public struct ComputeProcess: Codable, Identifiable, Sendable {
    public var id: pid_t { pid }
    public var pid: pid_t
    public var name: String
    public var cpu: Double?
    public var gpu: Double?
}

public struct ComputeProgram: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var processes: [ComputeProcess]
    public var contexts: [String]
    public var cpu: Double? { Self.total(processes.map(\.cpu)) }
    public var gpu: Double? { Self.total(processes.map(\.gpu)) }
    // A partial sum must not masquerade as a complete program reading.
    static func total(_ values: [Double?]) -> Double? {
        guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return nil }
        return values.reduce(0) { $0 + ($1 ?? 0) }
    }
    /// GPU counters cover reporting clients only; helpers without a GPU client are excluded.
    public var observedGPU: Double? {
        let values = processes.compactMap(\.gpu)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    public var gpuReportingProcesses: Int { processes.filter { $0.gpu != nil }.count }
}

public struct ComputeActivity: Codable, Sendable {
    public var sampled: Date
    public var cpu: Double?
    public var cores: Int
    public var devices: [GPUDeviceActivity]
    public var programs: [ComputeProgram]
}

/// Queue-confined, read-only sampling. Host CPU is normalized to the machine's capacity;
/// process CPU is 100% per core. GPU process rates are reporting-client GPU nanoseconds / time.
public final class ComputeSampler {
    struct Baseline { var at: UInt64; var processes: [pid_t: ProcessUsage]; var host: [UInt32]?; var clients: [UInt64: GPUClientCounter] }
    private var previous: Baseline?
    private let gpuReader: () -> ([GPUDeviceActivity], [GPUClientCounter])
    public init() { gpuReader = Self.readGPU }
    init(gpuReader: @escaping () -> ([GPUDeviceActivity], [GPUClientCounter])) { self.gpuReader = gpuReader }
    public func reset() { previous = nil }

    static func sameProcess(_ current: ProcessUsage, _ previous: ProcessUsage) -> Bool {
        current.pid == previous.pid && current.started != nil && current.started == previous.started &&
        current.uid == previous.uid && current.name == previous.name
    }
    static func rate(_ current: UInt64, _ previous: UInt64, elapsed: UInt64) -> Double? {
        guard elapsed > 0, elapsed <= 30_000_000_000, current >= previous else { return nil }
        return Double(current - previous) / Double(elapsed) * 100
    }
    static func hostRate(_ current: [UInt32], _ previous: [UInt32]) -> Double? {
        guard current.count == 4, previous.count == 4 else { return nil }
        let d = zip(current, previous).map { UInt64($0 &- $1) }
        let total = d.reduce(0, +)
        guard total > 0 else { return nil }
        return Double(total - d[Int(CPU_STATE_IDLE)]) / Double(total) * 100
    }
    static func clientRate(_ current: GPUClientCounter, _ previous: GPUClientCounter, elapsed: UInt64) -> Double? {
        guard current.id == previous.id, current.pid == previous.pid, current.counters.count == previous.counters.count, !current.counters.isEmpty else { return nil }
        let values = zip(current.counters, previous.counters).map { rate($0, $1, elapsed: elapsed) }
        return ComputeProgram.total(values)
    }

    public func sample(includeGPU: Bool = true, cancelled: () -> Bool = { false }) -> ComputeActivity {
        func cancelledReading() -> ComputeActivity {
            previous = nil
            return ComputeActivity(sampled: Date(), cpu: nil, cores: ProcessInfo.processInfo.activeProcessorCount,
                                   devices: [], programs: [])
        }
        guard !cancelled() else { return cancelledReading() }
        let usage = ProcessTable.usage(uid: nil, cancelled: cancelled).filter { u in
            guard !cancelled() else { return false }
            // Enumeration and counters are separate kernel reads. Drop a replaced PID.
            guard let start = u.started else { return true }
            return start == ProcessTable.started(u.pid)
        }
        guard !cancelled() else { return cancelledReading() }
        let host = Self.hostTicks()
        let (devices, clients) = includeGPU ? gpuReader() : ([], [])
        guard !cancelled() else { return cancelledReading() }
        let now = DispatchTime.now().uptimeNanoseconds
        let baseline = previous
        let elapsed = baseline.map { now >= $0.at ? now - $0.at : 0 } ?? 0
        let valid = elapsed > 0 && elapsed <= 30_000_000_000
        let byPID = Dictionary(usage.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var gpuByPID: [pid_t: [Double?]] = [:]
        for c in clients {
            guard !cancelled() else { return cancelledReading() }
            guard let current = byPID[c.pid], let old = baseline?.processes[c.pid], Self.sameProcess(current, old),
                  let before = baseline?.clients[c.id], valid else {
                gpuByPID[c.pid, default: []].append(nil); continue
            }
            gpuByPID[c.pid, default: []].append(Self.clientRate(c, before, elapsed: elapsed))
        }
        var readings: [pid_t: ComputeProcess] = [:]
        var candidates: [MachinePulse.Candidate] = []
        for u in usage {
            guard !cancelled() else { return cancelledReading() }
            var cpu: Double?
            if valid, u.cpuAvailable, let old = baseline?.processes[u.pid], old.cpuAvailable,
               Self.sameProcess(u, old) {
                cpu = Self.rate(u.cpuNanos, old.cpuNanos, elapsed: elapsed)
            }
            readings[u.pid] = ComputeProcess(pid: u.pid, name: u.name, cpu: cpu, gpu: gpuByPID[u.pid].flatMap(ComputeProgram.total))
            candidates.append(.init(pid: u.pid, uid: u.uid, name: u.name, cpu: cpu ?? 0, memoryKB: u.footprintKB,
                                    details: ProcessTable.details(u.pid), uptime: u.started.map { Date().timeIntervalSince($0) }))
        }
        guard !cancelled() else { return cancelledReading() }
        let contexts = MachinePulse.group(candidates, byMemory: false, me: getpid(), limit: nil)
        guard !cancelled() else { return cancelledReading() }
        let programs = MemoryInventory.group(contexts).map { group in
            ComputeProgram(id: group.id, name: group.name, processes: group.contexts.flatMap(\.pids).compactMap { readings[$0] },
                           contexts: group.contexts.compactMap { $0.project ?? $0.app })
        }
        let cpu = valid ? host.flatMap { current in baseline?.host.flatMap { Self.hostRate(current, $0) } } : nil
        guard !cancelled() else { return cancelledReading() }
        previous = Baseline(at: now, processes: byPID, host: host,
                            clients: Dictionary(clients.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
        return ComputeActivity(sampled: Date(), cpu: cpu, cores: ProcessInfo.processInfo.activeProcessorCount, devices: devices, programs: programs)
    }

    private static func hostTicks() -> [UInt32]? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self(); defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
    }
    static func percent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let n = number.doubleValue
        return n.isFinite && (0...100).contains(n) ? n : nil
    }
    static func counters(_ properties: [String: Any]) -> [UInt64]? {
        func counter(_ value: Any?) -> UInt64? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue.rounded() == n.doubleValue else { return nil }
            return n.uint64Value
        }
        if let direct = counter(properties["accumulatedGPUTime"]) { return [direct] }
        guard let usage = properties["AppUsage"] as? [[String: Any]], !usage.isEmpty else { return nil }
        let values = usage.map { counter($0["accumulatedGPUTime"]) }
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        return values.compactMap { $0 }
    }
    private static func readGPU() -> ([GPUDeviceActivity], [GPUClientCounter]) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return ([], []) }
        defer { IOObjectRelease(iterator) }
        func properties(_ entry: io_registry_entry_t) -> [String: Any] {
            var p: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &p, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let p else { return [:] }
            return p.takeRetainedValue() as NSDictionary as? [String: Any] ?? [:]
        }
        var devices: [GPUDeviceActivity] = []; var clients: [GPUClientCounter] = []
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            var id: UInt64 = 0; IORegistryEntryGetRegistryEntryID(device, &id)
            let p = properties(device); let stats = p["PerformanceStatistics"] as? [String: Any] ?? [:]
            devices.append(.init(id: id, name: p["model"] as? String ?? "GPU",
                                 percent: percent(stats["Device Utilization %"] ?? stats["GPU Activity(%)"])))
            var children: io_iterator_t = 0
            guard IORegistryEntryCreateIterator(device, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let child = IOIteratorNext(children), child != 0 {
                defer { IOObjectRelease(child) }
                let p = properties(child)
                guard let creator = p["IOUserClientCreator"] as? String,
                      creator.hasPrefix("pid "), let pid = pid_t(creator.dropFirst(4).split(separator: ",").first.map(String.init) ?? ""),
                      let values = counters(p) else { continue }
                var id: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(child, &id) == KERN_SUCCESS else { continue }
                clients.append(.init(id: id, pid: pid, counters: values))
            }
        }
        return (devices, clients)
    }
}
