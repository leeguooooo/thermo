import Foundation

/// What grew since an earlier complete overview: the answer to "who is eating my disk" when space runs out.
public struct SpaceGrowth: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var title: String
        public var path: String?
        public var changeBytes: Int64
        public var currentBytes: Int64
    }
    /// When the earlier measurement was taken.
    public var since: Date
    /// Free space then minus free space now; positive means the disk filled up.
    public var freeDropBytes: Int64
    public var items: [Item]
}

/// Compact snapshots of complete overviews, so the next one can say what grew.
/// Sizes only: no file names below the folders the overview already lists.
public enum OverviewHistory {
    struct Snapshot: Codable {
        var at: Date
        var free: Int64
        /// Folder path (or "#heading-id" for headings without a path) → bytes.
        var sizes: [String: Int64]
        var titles: [String: String]
    }

    public static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/dev.thermo/space-overview-history.jsonl")
    }
    static let keep: TimeInterval = 14 * 86_400
    /// Never compare with anything younger, so "grew" means over hours, not between two clicks.
    static let minimumAge: TimeInterval = 12 * 3_600
    static let threshold: Int64 = 1_000_000_000

    static func snapshot(_ overview: SpaceOverview, at: Date) -> Snapshot {
        var sizes: [String: Int64] = [:], titles: [String: String] = [:]
        func add(_ e: SpaceOverview.Entry) {
            guard e.effectiveSizeState == .complete, e.id != "other" else { return }
            let key = e.path ?? "#" + e.id
            sizes[key] = e.bytes; titles[key] = e.title
        }
        for e in overview.entries { add(e); e.children.forEach(add) }
        return Snapshot(at: at, free: overview.free, sizes: sizes, titles: titles)
    }

    static func read(_ url: URL) -> [Snapshot] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(Snapshot.self, from: Data($0.utf8)) }.sorted { $0.at < $1.at }
    }

    /// Growth over about a day: against the snapshot closest to 24 h old among those at least `minimumAge` old;
    /// nil when there is none or nothing grew by 1 GB.
    static func growth(_ current: Snapshot, history: [Snapshot]) -> SpaceGrowth? {
        let candidates = history.filter { current.at.timeIntervalSince($0.at) >= minimumAge }
        guard let base = candidates.min(by: { abs(current.at.timeIntervalSince($0.at) - 86_400) < abs(current.at.timeIntervalSince($1.at) - 86_400) })
        else { return nil }
        // A heading includes its folders: list a folder, and drop the heading when one of its folders explains the growth.
        let items = current.sizes.compactMap { key, bytes -> SpaceGrowth.Item? in
            guard let before = base.sizes[key], bytes - before >= threshold else { return nil }
            return .init(title: current.titles[key] ?? key, path: key.hasPrefix("#") ? nil : key, changeBytes: bytes - before, currentBytes: bytes)
        }.sorted { $0.changeBytes > $1.changeBytes }
        let folders = items.filter { $0.path != nil }
        let shown = folders.isEmpty ? items : folders
        guard !shown.isEmpty else { return nil }
        return SpaceGrowth(since: base.at, freeDropBytes: base.free - current.free, items: Array(shown.prefix(5)))
    }

    /// Adds this complete overview and returns what grew since an earlier one. One snapshot per hour, 14 days kept.
    @discardableResult
    public static func record(_ overview: SpaceOverview, at: Date = Date(), to url: URL = url) -> SpaceGrowth? {
        let current = snapshot(overview, at: at)
        var history = read(url).filter { at.timeIntervalSince($0.at) < keep && $0.at <= at }
        let growth = growth(current, history: history)
        if let last = history.last, at.timeIntervalSince(last.at) < 3_600 { history.removeLast() }
        history.append(current)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let lines = history.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
        return growth
    }
}
