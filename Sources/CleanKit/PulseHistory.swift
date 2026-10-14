import Foundation

/// A slowdown you can look back at: one line per minute (five on battery) of load, memory, swap,
/// thermal state and the three biggest programs, kept for 24 hours in
/// ~/Library/Application Support/Thermo/pulse-history.jsonl.
public struct PulseRecord: Codable, Sendable, Equatable {
    public struct Program: Codable, Sendable, Equatable {
        public var name: String
        public var cpu: Double
        public var memoryKB: Int
        public var project: String?
        public var owner: String?
    }

    public var t: Date
    public var load1: Double
    public var cores: Int
    public var memory: MachinePulse.Memory
    public var swapUsedMB: Int
    public var swapTotalMB: Int
    public var thermal: MachinePulse.Thermal
    public var top: [Program]
    /// Memory in use (app, wired, compressed) and compressed, MiB; absent in older lines.
    public var usedMB: Int? = nil
    public var compressedMB: Int? = nil

    public init(_ p: MachinePulse, memory breakdown: MemoryBreakdown? = MemoryBreakdown.read()) {
        t = p.sampled
        load1 = p.load1
        cores = p.cores
        memory = p.memory
        swapUsedMB = p.swapUsedMB
        swapTotalMB = p.swapTotalMB
        thermal = p.thermal
        // The three that matter most at that moment: busiest first, then the biggest.
        let byLoad = p.hogs.sorted { ($0.cpu, $0.memoryKB) > ($1.cpu, $1.memoryKB) }
        let biggest = p.hogs.sorted { $0.memoryKB > $1.memoryKB }
        var picked: [MachinePulse.Hog] = []
        for h in byLoad.prefix(2) + biggest where !picked.contains(where: { $0.id == h.id }) && picked.count < 3 { picked.append(h) }
        top = picked.map { Program(name: $0.name, cpu: $0.cpu, memoryKB: $0.memoryKB, project: $0.project, owner: $0.owner) }
        usedMB = breakdown.map { Int($0.used >> 20) }
        compressedMB = breakdown.map { Int($0.compressed >> 20) }
    }

    public init(t: Date, load1: Double, cores: Int, memory: MachinePulse.Memory, swapUsedMB: Int, swapTotalMB: Int,
                thermal: MachinePulse.Thermal, top: [Program]) {
        self.t = t; self.load1 = load1; self.cores = cores; self.memory = memory; self.swapUsedMB = swapUsedMB
        self.swapTotalMB = swapTotalMB; self.thermal = thermal; self.top = top
    }
}

public final class PulseHistory: @unchecked Sendable {
    public static let keep: TimeInterval = 24 * 3600

    public let url: URL
    private let lock = NSLock()
    private var appendsSinceCompact = 0

    public init(url: URL = PulseHistory.defaultURL) { self.url = url }

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Thermo/pulse-history.jsonl")
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    /// Adds one line. Every hour (and on the first append) the file is cut back to 24 hours.
    public func append(_ r: PulseRecord, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard var line = try? Self.encoder.encode(r) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: url)
        }
        if appendsSinceCompact == 0 || appendsSinceCompact >= 60 { compactLocked(now: now) }
        appendsSinceCompact += 1
    }

    /// Drops lines older than 24 hours (and any that do not parse).
    public func compact(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        compactLocked(now: now)
    }

    private func compactLocked(now: Date) {
        appendsSinceCompact = 1
        let kept = readLocked().filter { now.timeIntervalSince($0.t) <= Self.keep }
        var data = Data()
        for r in kept { if let l = try? Self.encoder.encode(r) { data.append(l); data.append(0x0A) } }
        try? data.write(to: url, options: .atomic)
    }

    /// Records since `since`, oldest first.
    public func records(since: Date) -> [PulseRecord] {
        lock.lock(); defer { lock.unlock() }
        return readLocked().filter { $0.t >= since }
    }

    private func readLocked() -> [PulseRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(PulseRecord.self, from: Data($0)) }
            .sorted { $0.t < $1.t }
    }

    // MARK: who slowed the Mac down

    public struct Share: Codable, Sendable, Equatable {
        public var name: String
        /// Minutes this program was among the top three while the Mac was busy or short on memory.
        public var minutes: Int
        public var peakCPU: Double
        public var peakMemoryKB: Int
        public var project: String?
        public var owner: String?
    }

    /// Ranks programs by how long they were at the top while the Mac was struggling (load ≥ cores,
    /// memory pressure, or throttling). Each record counts for the time until the next one.
    public static func blame(_ records: [PulseRecord], interval: TimeInterval = 60) -> [Share] {
        var byName: [String: Share] = [:]
        for (i, r) in records.enumerated() {
            let struggling = r.load1 >= Double(max(1, r.cores)) || r.memory.isHigh || r.thermal == .serious || r.thermal == .critical
            guard struggling else { continue }
            let span = i + 1 < records.count ? min(records[i + 1].t.timeIntervalSince(r.t), 10 * 60) : interval
            for p in r.top {
                var s = byName[p.name] ?? Share(name: p.name, minutes: 0, peakCPU: 0, peakMemoryKB: 0, project: p.project, owner: p.owner)
                s.minutes += Int((span / 60).rounded())
                s.peakCPU = max(s.peakCPU, p.cpu)
                s.peakMemoryKB = max(s.peakMemoryKB, p.memoryKB)
                byName[p.name] = s
            }
        }
        return byName.values.sorted { ($0.minutes, $0.peakMemoryKB) > ($1.minutes, $1.peakMemoryKB) }
    }
}

// MARK: - Alerts

/// Tells you before you notice: swap growing past 8 GB, memory pressure critical for two minutes,
/// one program on more than 1.5 cores for ten minutes, or the Mac throttling itself. Each reason is
/// told at most once an hour. Nothing is ever quit automatically.
public struct SlowdownAlerts: Sendable {
    /// Every threshold in one place.
    public struct Limits: Sendable {
        public var swapGB: Double = 8
        public var memoryCriticalFor: TimeInterval = 2 * 60
        public var cpuPercent: Double = 150
        public var cpuFor: TimeInterval = 10 * 60
        public var cooldown: TimeInterval = 3600
        public init() {}
    }

    public struct Alert: Sendable, Equatable {
        /// Identifies the reason for the cooldown, e.g. "swap", "cpu:Google Chrome".
        public var key: String
        public var title: String
        public var body: String
        /// The program to point at in the Overview, if any.
        public var program: String?
    }

    public var limits = Limits()
    /// Reason key → when it was last told.
    public private(set) var lastFired: [String: Date] = [:]

    public init(limits: Limits = Limits()) { self.limits = limits }

    /// What to tell now, given the recent history (oldest first, including the latest) and the
    /// latest full sample (for advice such as "restart Chrome").
    public mutating func evaluate(_ recent: [PulseRecord], latest: MachinePulse, now: Date = Date()) -> [Alert] {
        guard let last = recent.last else { return [] }
        var out: [Alert] = []
        func held(for span: TimeInterval, _ ok: (PulseRecord) -> Bool) -> Bool {
            // Every record in the window holds, and the window really is that long.
            let window = recent.filter { now.timeIntervalSince($0.t) <= span + 30 }
            guard let first = window.first, now.timeIntervalSince(first.t) >= span - 30 else { return false }
            return window.allSatisfy(ok)
        }
        let biggest = latest.hogs.max { $0.memoryKB < $1.memoryKB }
        func advice(for name: String?) -> String? { latest.hogs.first { $0.name == name }?.advice?.text }

        // Swap past the limit and still growing.
        if Double(last.swapUsedMB) / 1024 >= limits.swapGB,
           let earlier = recent.first(where: { now.timeIntervalSince($0.t) <= 15 * 60 }), last.swapUsedMB > earlier.swapUsedMB {
            let who = biggest.map { tr("%1$@ uses %2$@.", $0.name, MachinePulse.gb($0.memoryKB)) } ?? ""
            out.append(Alert(key: "swap", title: tr("Your Mac is running out of memory"),
                             body: [tr("%1$@ of memory has been moved to the disk and it keeps growing.", MachinePulse.gb(last.swapUsedMB * 1024)),
                                    advice(for: biggest?.name) ?? who].filter { !$0.isEmpty }.joined(separator: " "),
                             program: biggest?.name))
        }
        if held(for: limits.memoryCriticalFor, { $0.memory == .critical }) {
            out.append(Alert(key: "memory", title: tr("Memory is critically low"),
                             body: biggest.map { advice(for: $0.name) ?? tr("%1$@ uses the most memory (%2$@).", $0.name, MachinePulse.gb($0.memoryKB)) } ?? "",
                             program: biggest?.name))
        }
        // The same program on more than 1.5 cores for the whole window.
        for p in last.top where p.cpu >= limits.cpuPercent {
            if held(for: limits.cpuFor, { r in r.top.contains { $0.name == p.name && $0.cpu >= limits.cpuPercent } }) {
                let place = [p.project, p.owner.map { tr("started by %1$@", $0) }].compactMap { $0 }.joined(separator: " · ")
                out.append(Alert(key: "cpu:\(p.name)", title: tr("%1$@ has been busy for 10 minutes", p.name),
                                 body: tr("It is using %1$@ cores.", String(format: "%.1f", p.cpu / 100))
                                    + (place.isEmpty ? "" : " " + place),
                                 program: p.name))
            }
        }
        if last.thermal == .serious || last.thermal == .critical {
            out.append(Alert(key: "thermal", title: tr("Your Mac is too hot and is slowing itself down"),
                             body: last.top.first.map { tr("%1$@ is the busiest program.", $0.name) } ?? "", program: last.top.first?.name))
        }
        // Once an hour per reason.
        let fresh = out.filter { a in lastFired[a.key].map { now.timeIntervalSince($0) >= limits.cooldown } ?? true }
        for a in fresh { lastFired[a.key] = now }
        return fresh
    }
}
