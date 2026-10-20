import AgentCore
import Darwin
import Foundation

/// Where the memory is, the way Activity Monitor splits it, plus swap and the room swap has to grow.
public struct MemoryBreakdown: Codable, Sendable, Equatable {
    public var total: UInt64
    /// Memory programs asked for and still hold in RAM.
    public var app: UInt64
    /// Kernel and drivers; can never be compressed or swapped.
    public var wired: UInt64
    /// RAM the compressor occupies, and how much memory it holds in that space.
    public var compressed: UInt64
    public var compressedHolds: UInt64
    /// Copies of files kept in RAM; given back the moment a program needs it.
    public var cached: UInt64
    public var free: UInt64
    public var pressure: MachinePulse.Memory
    public var swapUsed: UInt64
    /// Size of the swap files on the disk (they stay until memory frees up).
    public var swapFiles: UInt64
    /// Free disk space: swap can only grow into this.
    public var diskAvailable: Int64? = nil
    public var swapReadable: Bool? = nil
    public var diskFree: Int64?
    /// Pages written to and read back from swap since startup.
    public var swapOuts: UInt64
    public var swapIns: UInt64
    public var sampled: Date

    /// "Memory used" as Activity Monitor shows it.
    public var used: UInt64 { app + wired + compressed }

    public static func read() -> MemoryBreakdown? {
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
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let swapOK = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
        let disk = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return MemoryBreakdown(total: ProcessInfo.processInfo.physicalMemory, app: app * page, wired: UInt64(stats.wire_count) * page,
                               compressed: UInt64(stats.compressor_page_count) * page,
                               compressedHolds: UInt64(stats.total_uncompressed_pages_in_compressor) * page,
                               cached: (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * page,
                               free: UInt64(stats.free_count) * page, pressure: MachinePulse.memoryLevel(),
                               swapUsed: swap.xsu_used, swapFiles: swap.xsu_total, diskAvailable: disk?.volumeAvailableCapacityForImportantUsage,
                               swapReadable: swapOK, diskFree: disk?.volumeAvailableCapacity.map(Int64.init),
                               swapOuts: stats.swapouts, swapIns: stats.swapins, sampled: Date())
    }

    /// Swap needs free disk to grow; when the disk is nearly full macOS shows "Your system has run
    /// out of application memory" and asks you to force quit apps, however much RAM is in use.
    public var swapBlocked: Bool {
        guard let free = diskAvailable ?? diskFree else { return false }
        return free < 5 << 30 && (swapUsed >= 2 << 30 || pressure.isHigh)
    }

    /// What is going on, in one or two sentences.
    public var summary: String {
        if swapBlocked {
            return tr("Disk space available to swap is low (%1$@). Free disk space and check memory pressure.",
                      ByteFormat.string(diskAvailable ?? diskFree ?? 0))
        }
        switch pressure {
        case .unknown: return tr("Memory pressure could not be read. Refresh before taking action.")
        case .critical: return tr("Memory pressure is critical. Save your work, then inspect programs you can stop.")
        case .warning: return tr("Memory pressure is high. Check current swap activity and the largest programs.")
        case .normal:
            return swapUsed >= 4 << 30
                ? tr("Memory pressure is normal right now. Swap is still in use; its size alone does not show current memory pressure.")
                : tr("Memory is fine: there is room for what you run.")
        }
    }
}

/// Programs' memory over the day, to tell a program that keeps growing (a leak, or a page that
/// piles up) from one that is simply big. One line every few minutes in
/// ~/Library/Application Support/Thermo/memory-history.jsonl, kept 24 hours.
public struct ProgramMemoryRecord: Codable, Sendable, Equatable {
    public var t: Date
    /// Program id (as in MachinePulse.Hog) → KiB; only programs above 200 MB.
    public var programs: [String: Int]
    public var names: [String: String]
    public var identities: [String: [ProcessIdentity]]? = nil

    public init(t: Date, programs: [String: Int], names: [String: String]) {
        self.t = t; self.programs = programs; self.names = names
    }

    public init(_ hogs: [MachinePulse.Hog], at t: Date = Date()) {
        let big = hogs.filter { $0.memoryKB >= 200 * 1024 && ($0.memoryMetric == nil || $0.memoryMetric == .footprint) }
        self.init(t: t, programs: Dictionary(big.map { ($0.id, $0.memoryKB) }, uniquingKeysWith: max),
                  names: Dictionary(big.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
        identities = Dictionary(big.compactMap { h -> (String, [ProcessIdentity])? in
            guard h.memoryMetric == nil || h.memoryMetric == .footprint,
                  let ids = h.processIdentities, !ids.isEmpty, ids.count == h.pids.count else { return nil }
            return (h.id, ids.sorted { $0.pid < $1.pid })
        }, uniquingKeysWith: { a, _ in a })
    }
}

public final class ProgramMemoryHistory: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL = ProgramMemoryHistory.defaultURL) { self.url = url }

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Thermo/memory-history.jsonl")
    }

    public func append(_ r: ProgramMemoryRecord, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var kept = readLocked().filter { now.timeIntervalSince($0.t) <= PulseHistory.keep }
        kept.append(r)
        var data = Data()
        for k in kept { if let l = try? PulseHistory.encoder.encode(k) { data.append(l); data.append(0x0A) } }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public func records(since: Date) -> [ProgramMemoryRecord] {
        lock.lock(); defer { lock.unlock() }
        return readLocked().filter { $0.t >= since }
    }

    private func readLocked() -> [ProgramMemoryRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? PulseHistory.decoder.decode(ProgramMemoryRecord.self, from: Data($0)) }
            .sorted { $0.t < $1.t }
    }
}

/// A program worth a second look: it keeps growing, or it has run for days and got big.
public struct MemorySuspect: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case growing, longRunning }
    public var id: String
    public var name: String
    public var kind: Kind
    public var memoryKB: Int
    /// Growing: how much it added over `span`.
    public var grewKB: Int?
    public var span: TimeInterval?
    public var uptime: TimeInterval?

    public var text: String {
        switch kind {
        case .growing:
            return tr("grew by %1$@ in %2$@ across comparable readings; inspect its processes before taking action",
                      MemoryFormat.string(kibibytes: grewKB ?? 0), MemorySuspects.duration(span ?? 0))
        case .longRunning:
            return tr("running for %1$@ and using %2$@; long-running apps pile up memory, a restart usually frees most of it",
                      MemorySuspects.duration(uptime ?? 0), MemoryFormat.string(kibibytes: memoryKB))
        }
    }
}

public enum MemorySuspects {
    /// Growing: at least an hour of readings, now ≥ 500 MB, up ≥ 300 MB and ≥ 50 % from its lowest,
    /// and still near its highest (a program that grew and came back down is just working).
    /// Age/size alone never generates a suspect. The legacy longRunning case remains decodable.
    public static func find(programs: [MachinePulse.Hog], history: [ProgramMemoryRecord], now: Date = Date()) -> [MemorySuspect] {
        var out: [MemorySuspect] = []
        // Every program traverses the same timeline; sort it once, outside the per-program loop.
        let newestFirst = history.sorted { $0.t > $1.t }
        for h in programs {
            guard h.memoryMetric == nil || h.memoryMetric == .footprint else { continue }
            // Only the uninterrupted tail with the same PID/start/executable set is comparable.
            // Old records without identities and process restarts must not become "growth".
            let current = h.processIdentities?.sorted { $0.pid < $1.pid }
            var comparable: [ProgramMemoryRecord] = []
            if let current, !current.isEmpty, current.count == h.pids.count {
                for r in newestFirst where r.t <= now {
                    guard r.identities?[h.id] == current, r.programs[h.id] != nil else { break }
                    comparable.append(r)
                }
            }
            let points = comparable.reversed().compactMap { r in r.programs[h.id].map { (r.t, $0) } } + [(now, h.memoryKB)]
            if let first = points.first, now.timeIntervalSince(first.0) >= 3600, points.count >= 4, h.memoryKB >= 500 * 1024 {
                let low = points.map(\.1).min() ?? h.memoryKB
                let high = points.map(\.1).max() ?? h.memoryKB
                let lowAt = points.first { $0.1 == low }?.0 ?? first.0
                if h.memoryKB - low >= 300 * 1024, Double(h.memoryKB) >= Double(low) * 1.5, Double(h.memoryKB) >= Double(high) * 0.9 {
                    out.append(MemorySuspect(id: h.id, name: h.name, kind: .growing, memoryKB: h.memoryKB, grewKB: h.memoryKB - low,
                                             span: now.timeIntervalSince(lowAt), uptime: h.uptime))
                    continue
                }
            }
        }
        return out.sorted { ($0.kind == .growing ? 1 : 0, $0.memoryKB) > ($1.kind == .growing ? 1 : 0, $1.memoryKB) }
    }

    /// "26 h", "3 d", "45 min".
    public static func duration(_ s: TimeInterval) -> String {
        if s >= 2 * 86400 { return tr("%1$@ d", String(Int(s / 86400))) }
        if s >= 3600 { return tr("%1$@ h", String(Int(s / 3600))) }
        if s >= 60 { return tr("%1$@ min", String(Int(s / 60))) }
        return tr("%1$@ s", String(max(0, Int(s))))
    }
}

/// Counter deltas, not the amount of swap retained from earlier. A reset/invalid interval is unknown.
public struct MemoryActivity: Sendable, Equatable {
    public let swapReadBytesPerSecond: Double
    public let swapWriteBytesPerSecond: Double

    public init?(previous: MemoryBreakdown?, current: MemoryBreakdown, pageSize: UInt64 = UInt64(vm_kernel_page_size)) {
        guard let previous else { return nil }
        let seconds = current.sampled.timeIntervalSince(previous.sampled)
        guard seconds.isFinite, seconds >= 1, seconds <= 60,
              current.swapIns >= previous.swapIns, current.swapOuts >= previous.swapOuts else { return nil }
        swapReadBytesPerSecond = Double(current.swapIns - previous.swapIns) * Double(pageSize) / seconds
        swapWriteBytesPerSecond = Double(current.swapOuts - previous.swapOuts) * Double(pageSize) / seconds
    }
}
