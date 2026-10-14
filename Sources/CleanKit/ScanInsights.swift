import CryptoKit
import Foundation

public struct CleanSpaceContext: Codable, Sendable {
    public var swapUsed: Int64?
    public var swapFiles: Int64?
    public var simulatorRuntimes: Int64?
    public var purgeable: Int64?
    public var note: String

    static func read(home: String, cancellation: ScanCancellation) -> CleanSpaceContext {
        let memory = MemoryBreakdown.read()
        let capacity = try? URL(fileURLWithPath: home).resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let (status, json) = Shell.exec(["xcrun", "simctl", "runtime", "list", "-j"], timeout: 5, cancellation: cancellation)
        let runtimes = status == 0 ? try? JSONDecoder().decode([String: Simulators.Runtime].self, from: Data(json.utf8)) : nil
        let runtimeBytes = runtimes.flatMap { r -> Int64? in
            guard r.values.allSatisfy({ $0.sizeBytes != nil }) else { return nil }
            return r.values.reduce(0) { $0 + ($1.sizeBytes ?? 0) }
        }
        let purgeable = capacity?.volumeAvailableCapacity.flatMap { free in
            capacity?.volumeAvailableCapacityForImportantUsage.map { max(0, $0 - Int64(free)) }
        }
        return CleanSpaceContext(swapUsed: memory?.swapReadable == true ? memory.map { Int64($0.swapUsed) } : nil,
                                 swapFiles: memory?.swapReadable == true ? memory.map { Int64($0.swapFiles) } : nil,
                                 simulatorRuntimes: runtimeBytes, purgeable: purgeable,
                                 note: "Swap: vm.swapusage; runtimes: simctl; purgeable: volume capacity estimate. These share the APFS container and are not additive to folder totals; no process attribution is inferred.")
    }
}

public struct ScanGrowth: Codable, Sendable {
    public var id: String
    public var title: String
    public var changeBytes: Int64
    public var previousBytes: Int64
    public var currentBytes: Int64
}

public enum CleanScanHistory {
    struct Scope: Codable, Equatable {
        var schema = 1
        var categories: [String]
        var roots: [String]
        var olderThan: Int
        var discover: Bool
        var exact: Bool
        init(_ report: ScanReport) {
            categories = (report.categories ?? CleanCategory.allCases).map(\.rawValue).sorted()
            roots = (report.projectRoots ?? []).sorted()
            olderThan = report.olderThanDays ?? 30
            discover = report.discoverProjectRoots ?? true
            exact = report.exactSizes ?? false
        }
    }
    struct Snapshot: Codable {
        var scope: Scope
        var report: ScanReport
    }
    private static let lock = NSLock()

    /// Only complete, readable measurements in precisely the same scope form a baseline.
    static func compare(_ report: ScanReport, with previous: ScanReport) -> [ScanGrowth]? {
        guard report.items.allSatisfy({ $0.bytes >= 0 }), previous.items.allSatisfy({ $0.bytes >= 0 }),
              !report.cancelled, !previous.cancelled, report.denied.isEmpty, previous.denied.isEmpty,
              Scope(report) == Scope(previous), previous.started < report.started,
              !report.items.contains(where: { $0.sizeIncomplete == true }),
              !previous.items.contains(where: { $0.sizeIncomplete == true }) else { return nil }
        let old = Dictionary(previous.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return report.items.compactMap { item in
            guard let before = old[item.id], before.estimatedSize == item.estimatedSize else { return nil }
            let change = item.bytes - before.bytes
            guard change != 0 else { return nil }
            return ScanGrowth(id: item.id, title: item.title, changeBytes: change, previousBytes: before.bytes, currentBytes: item.bytes)
        }.sorted { $0.changeBytes > $1.changeBytes }
    }

    static func record(_ report: inout ScanReport, home: String) {
        lock.lock(); defer { lock.unlock() }
        let dir = URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/dev.thermo/scan-history")
        let scope = Scope(report)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(scope) else { return }
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let url = dir.appendingPathComponent(key + ".json")
        if let bytes = try? Data(contentsOf: url), let old = try? JSONDecoder().decode(Snapshot.self, from: bytes),
           old.scope == scope, let changes = compare(report, with: old.report) {
            report.changesSince = old.report.started
            report.growth = changes
        }
        // Keep partial snapshots for inspection without replacing a complete comparison baseline.
        let samples = dir.appendingPathComponent("samples")
        try? FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        if let snapshot = try? encoder.encode(Snapshot(scope: scope, report: report)) {
            let name = String(format: "%020.3f", report.started.timeIntervalSince1970) + "-" + UUID().uuidString + ".json"
            try? snapshot.write(to: samples.appendingPathComponent(name), options: .atomic)
        }
        let sampleFiles = ((try? FileManager.default.contentsOfDirectory(at: samples, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in sampleFiles.dropFirst(24) { try? FileManager.default.removeItem(at: old) }
        guard !report.cancelled, report.denied.isEmpty, !report.items.contains(where: { $0.sizeIncomplete == true }) else { return }
        var baseline = report
        baseline.growth = nil; baseline.changesSince = nil
        guard let encoded = try? JSONEncoder().encode(Snapshot(scope: scope, report: baseline)) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? encoded.write(to: url, options: .atomic)
        // Bound scope variants; changing filters must not grow this cache indefinitely.
        let saved = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let ordered = saved.sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        for old in ordered.dropFirst(32) where old.pathExtension == "json" { try? FileManager.default.removeItem(at: old) }
    }
}
