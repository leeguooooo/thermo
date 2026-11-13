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
    /// Assigned on append, so two identical requests remain two distinct events.
    public var eventID: UUID? = nil
    /// Full precision append time keeps cross-stream ordering despite legacy second-resolution dates.
    public var loggedAt: Double? = nil
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
    private static let lock = NSLock()

    public init(home: String = NSHomeDirectory()) {
        directory = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Thermo/modules")
    }

    public func url(module: String) -> URL { directory.appendingPathComponent(module).appendingPathComponent("access.jsonl") }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e
    }
    private static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    private static func mutation(_ record: ModuleAccessRecord) -> Bool {
        record.outcome == .allowed && (record.capability == "files.delete" || record.capability == "processes.end")
    }

    private func read(_ files: [URL]) -> [ModuleAccessRecord] {
        let decoder = Self.decoder()
        return files.flatMap { file -> [ModuleAccessRecord] in
            guard let data = FileManager.default.contents(atPath: file.path) else { return [] }
            return data.split(separator: 10).compactMap { try? decoder.decode(ModuleAccessRecord.self, from: Data($0)) }
        }
    }

    private func append(_ line: Data, to file: URL, synchronize: Bool = false) throws {
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size + line.count > Self.maxBytes {
            let old = file.deletingPathExtension().appendingPathExtension("1.jsonl")
            if fm.fileExists(atPath: old.path) { try fm.removeItem(at: old) }
            try fm.moveItem(at: file, to: old)
        }
        if !fm.fileExists(atPath: file.path) {
            guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: line)
        if synchronize { try handle.synchronize() }
    }

    public func record(_ value: ModuleAccessRecord) {
        guard ModuleManifest.matches(ModuleManifest.identifier, value.module) else { return }
        var record = value
        record.eventID = UUID()
        record.loggedAt = Date().timeIntervalSince1970
        guard var line = try? Self.encoder().encode(record), line.count < Self.maxBytes else { return }
        line.append(10)
        Self.lock.lock(); defer { Self.lock.unlock() }
        let file = url(module: record.module)
        let folder = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Preserve old-format changes before read traffic can rotate their original stream.
            let legacy = folder.appendingPathComponent("changes-legacy.jsonl")
            if !FileManager.default.fileExists(atPath: legacy.path) {
                var data = Data()
                for old in read([folder.appendingPathComponent("access.1.jsonl"), file]) where old.eventID == nil && Self.mutation(old) {
                    data.append(try Self.encoder().encode(old)); data.append(10)
                }
                let temporary = folder.appendingPathComponent("changes-legacy." + UUID().uuidString + ".tmp")
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
                let handle = try FileHandle(forWritingTo: temporary)
                do { try handle.synchronize(); try handle.close() }
                catch { try? handle.close(); throw error }
                try FileManager.default.moveItem(at: temporary, to: legacy)
            }
            // Changes have their own bounded retention; a scan cannot evict them.
            if Self.mutation(record) { try append(line, to: folder.appendingPathComponent("changes.jsonl"), synchronize: true) }
            try append(line, to: file)
        } catch { return } // Logging never changes the result of an already completed request.
    }

    /// Oldest first. Changes survive read-stream rotation; duplicated stream copies count once.
    public func records(module: String) -> [ModuleAccessRecord] {
        guard ModuleManifest.matches(ModuleManifest.identifier, module) else { return [] }
        Self.lock.lock(); defer { Self.lock.unlock() }
        let live = url(module: module), folder = live.deletingLastPathComponent()
        let legacy = folder.appendingPathComponent("changes-legacy.jsonl")
        let migrated = FileManager.default.fileExists(atPath: legacy.path)
        let changes = read([legacy, folder.appendingPathComponent("changes.1.jsonl"), folder.appendingPathComponent("changes.jsonl")])
        let access = read([folder.appendingPathComponent("access.1.jsonl"), live]).filter {
            !(migrated && $0.eventID == nil && Self.mutation($0))
        }
        var seen = Set<UUID>()
        return (changes + access).enumerated().filter { _, record in
            record.eventID.map { seen.insert($0).inserted } ?? true
        }.sorted { a, b in
            let left = a.element.loggedAt ?? a.element.time.timeIntervalSince1970
            let right = b.element.loggedAt ?? b.element.time.timeIntervalSince1970
            return left == right ? a.offset < b.offset : left < right
        }.map(\.element)
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
