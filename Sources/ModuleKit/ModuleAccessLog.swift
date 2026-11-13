import Foundation

/// One request a module made of the kernel, granted or not. Together these answer, per module,
/// what it read, what it deleted and which hosts it reached.
public struct ModuleAccessRecord: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        /// Done.
        case allowed
        /// Not covered by the module's manifest, or against a kernel rule. Nothing was done.
        case denied
        /// The person said no when asked. Nothing was done.
        case declined
        /// Allowed, but it did not work.
        case failed
    }
    public var time: Date
    public var module: String
    /// The capability kind as written in manifests, e.g. `files.delete`. Unknown kinds are kept as sent.
    public var capability: String
    public var operation: String?
    /// Paths or hosts, at most `ModuleAccessLog.listedTargets` of them.
    public var targets: [String]
    /// How many targets the request named in all.
    public var targetCount: Int
    public var outcome: Outcome
    public var detail: String?

    public init(time: Date = Date(), module: String, capability: String, operation: String? = nil, targets: [String] = [],
                outcome: Outcome, detail: String? = nil) {
        self.time = time; self.module = module; self.capability = capability; self.operation = operation
        self.targets = Array(targets.prefix(ModuleAccessLog.listedTargets)); self.targetCount = targets.count
        self.outcome = outcome; self.detail = detail
    }
}

/// Append-only, one file per module, next to Thermo's operation history. Writing is best effort:
/// the log records what happened and never decides it.
public final class ModuleAccessLog: @unchecked Sendable {
    public static let listedTargets = 50
    public static let maxBytes = 2 * 1024 * 1024

    public struct Summary: Sendable, Equatable {
        public var read: [String] = []
        public var deleted: [String] = []
        public var hosts: [String] = []
        public var ended: [String] = []
        public var denied = 0
        public var declined = 0
        public var failed = 0
        public init() {}
    }

    private let directory: URL
    private let lock = NSLock()

    public init(home: String = NSHomeDirectory()) {
        directory = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Thermo/modules")
    }

    public func url(module: String) -> URL { directory.appendingPathComponent(module).appendingPathComponent("access.jsonl") }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e
    }
    private static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    public func record(_ record: ModuleAccessRecord) {
        // The module id becomes a folder name; anything that is not a plain id is not written.
        guard ModuleManifest.matches(ModuleManifest.identifier, record.module), var line = try? Self.encoder().encode(record) else { return }
        line.append(10)
        lock.lock(); defer { lock.unlock() }
        let file = url(module: record.module)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size + line.count > Self.maxBytes {
            let old = file.deletingLastPathComponent().appendingPathComponent("access.1.jsonl")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: file, to: old)
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// Oldest first, the rotated file included. Lines that cannot be read are skipped.
    public func records(module: String) -> [ModuleAccessRecord] {
        lock.lock(); defer { lock.unlock() }
        let live = url(module: module)
        let files = [live.deletingLastPathComponent().appendingPathComponent("access.1.jsonl"), live]
        let decoder = Self.decoder()
        return files.flatMap { file -> [ModuleAccessRecord] in
            guard let data = FileManager.default.contents(atPath: file.path) else { return [] }
            return data.split(separator: 10).compactMap { try? decoder.decode(ModuleAccessRecord.self, from: Data($0)) }
        }
    }

    /// What the module read, deleted, reached and ended; each target once, in first-seen order.
    public func summary(module: String) -> Summary {
        var summary = Summary()
        var seen = Set<String>()
        func add(_ list: inout [String], _ record: ModuleAccessRecord) {
            for target in record.targets where seen.insert(record.capability + "\u{0}" + target).inserted { list.append(target) }
        }
        for record in records(module: module) {
            switch record.outcome {
            case .denied: summary.denied += 1
            case .declined: summary.declined += 1
            case .failed: summary.failed += 1
            case .allowed:
                switch Capability.Kind(rawValue: record.capability) {
                case .filesRead: add(&summary.read, record)
                case .filesDelete: add(&summary.deleted, record)
                case .networkConnect: add(&summary.hosts, record)
                case .processesEnd: add(&summary.ended, record)
                default: break
                }
            }
        }
        return summary
    }
}
