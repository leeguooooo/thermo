import AgentCore
import Foundation

/// Presentation groups never become action targets. Contexts retain their original PID identities,
/// project boundaries and agent protection; a user acts on a context, not a merged name.
public struct MemoryProgram: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let contexts: [MachinePulse.Hog]
    public init(id: String, name: String, contexts: [MachinePulse.Hog]) {
        self.id = id; self.name = name; self.contexts = contexts
    }
    enum CodingKeys: String, CodingKey { case id, name, contexts, processCount, memoryKB, footprintKB, residentKB, memoryMetric, projects }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        contexts = try c.decode([MachinePulse.Hog].self, forKey: .contexts)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(contexts, forKey: .contexts)
        try c.encode(processCount, forKey: .processCount); try c.encode(memoryKB, forKey: .memoryKB)
        try c.encode(footprintKB, forKey: .footprintKB)
        try c.encodeIfPresent(residentKB, forKey: .residentKB); try c.encode(memoryMetric, forKey: .memoryMetric)
        try c.encode(projects, forKey: .projects)
    }
    public var processCount: Int { contexts.reduce(0) { $0 + $1.pids.count } }
    public var memoryKB: Int { contexts.reduce(0) { $0 + $1.memoryKB } }
    /// A complete footprint total is only available when every context used that metric.
    public var footprintKB: Int? { memoryMetric == .footprint ? memoryKB : nil }
    public var residentKB: Int? {
        guard contexts.allSatisfy({ $0.residentKB != nil }) else { return nil }
        return contexts.reduce(0) { $0 + ($1.residentKB ?? 0) }
    }
    public var memoryMetric: MachinePulse.MemoryMetric {
        let metrics = Set(contexts.map { ($0.memoryMetric ?? .footprint).rawValue })
        return metrics.count == 1 ? contexts.first?.memoryMetric ?? .footprint : .mixed
    }
    public var app: String? { contexts.count == 1 ? contexts[0].app : nil }
    public var projects: [String] { Array(Set(contexts.compactMap(\.project))).sorted() }
    public var actionTarget: MachinePulse.Hog? { contexts.count == 1 ? contexts[0] : nil }

    /// Synthetic history entry only. It cannot authorize a quit/end action.
    public var historyEntry: MachinePulse.Hog {
        var h = MachinePulse.Hog(id: id, name: name, cpu: contexts.reduce(0) { $0 + $1.cpu }, memoryKB: memoryKB,
                                 pids: contexts.flatMap(\.pids).sorted(), quittable: false,
                                 residentKB: residentKB, memoryMetric: memoryMetric)
        h.processIdentities = contexts.flatMap { $0.processIdentities ?? [] }
        return h
    }
}

public struct MemoryInventory: Codable, Sendable {
    public var sampled: Date
    public var programs: [MemoryProgram]
    public var processCount: Int
    public var unreadableCount: Int
    public var available: Bool

    public static func collect(cancelled: () -> Bool = { false }) -> MemoryInventory {
        let table = ProcessTable.current(.init(cpu: false), cancelled: cancelled)
        guard !cancelled(), table.available else {
            return MemoryInventory(sampled: Date(), programs: [], processCount: 0, unreadableCount: 0, available: false)
        }
        let identities = Dictionary(table.entries.compactMap { p in p.sampledIdentity.map { (p.pid, $0) } }, uniquingKeysWith: { a, _ in a })
        var contexts = MachinePulse.group(table.entries, byMemory: true, limit: nil)
        // Capture for both action validation and detecting restarted/replaced processes in history.
        for i in contexts.indices {
            contexts[i].processIdentities = contexts[i].pids.compactMap { identities[$0] }
        }
        return MemoryInventory(sampled: Date(), programs: group(contexts), processCount: table.entries.count,
                               unreadableCount: table.entries.filter {
                                   $0.memoryReading?.footprintKB == nil
                               }.count, available: !table.entries.isEmpty)
    }

    public static func group(_ contexts: [MachinePulse.Hog]) -> [MemoryProgram] {
        let groups = Dictionary(grouping: contexts) {
            ($0.app == nil ? "program:cmd:" : "program:app:") + $0.name.lowercased()
        }
        return groups.map { key, values in
            let sorted = values.sorted { a, b in
                a.memoryKB == b.memoryKB ? a.id < b.id : a.memoryKB > b.memoryKB
            }
            return MemoryProgram(id: key, name: sorted[0].name, contexts: sorted)
        }.sorted { a, b in
            a.memoryKB == b.memoryKB ? a.id < b.id : a.memoryKB > b.memoryKB
        }
    }
}

/// A footprint curve is useful even as workloads change. Such a curve is not leak evidence;
/// MemorySuspects separately requires an unchanged process identity set.
public struct MemoryTrendPoint: Identifiable, Sendable {
    public var id: Date { sampled }
    public var sampled: Date
    public var memoryKB: Int
    public var identities: [ProcessIdentity]?
}

public enum MemoryTrends {
    public static func points(for id: String, records: [ProgramMemoryRecord]) -> [MemoryTrendPoint] {
        records.sorted { $0.t < $1.t }.compactMap { r in
            r.programs[id].map { MemoryTrendPoint(sampled: r.t, memoryKB: $0, identities: r.identities?[id]) }
        }
    }
}
