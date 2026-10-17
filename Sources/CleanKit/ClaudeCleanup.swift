import AgentCore
import CryptoKit
import Darwin
import Foundation
import ThermoL10n

/// Explicit, recoverable Claude local resets. This does not grant the generic cleaner access.
public enum ClaudeResetTarget: String, CaseIterable, Codable, Sendable {
    case credentials, settings, globalConfig, codeData
    case desktopIdentity, desktopData, thirdPartyIdentity, thirdPartyData
    public var relativePath: String {
        switch self {
        case .credentials: return ".claude/.credentials.json"
        case .settings: return ".claude/settings.json"
        case .globalConfig: return ".claude.json"
        case .codeData: return ".claude"
        case .desktopIdentity: return "Library/Application Support/Claude/ant-did"
        case .desktopData: return "Library/Application Support/Claude"
        case .thirdPartyIdentity: return "Library/Application Support/Claude-3p/ant-did"
        case .thirdPartyData: return "Library/Application Support/Claude-3p"
        }
    }
}
public struct ClaudeResetCandidate: Encodable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable { case missing, available, blocked }
    public let target: ClaudeResetTarget
    public let path: String
    public let status: Status
    public let reason: String?
    public let bytes: Int64
    public let snapshot: String?
}
public struct ClaudeResetBatch: Codable, Identifiable, Sendable {
    public struct Entry: Codable, Sendable {
        public let target: ClaudeResetTarget
        public let snapshot: String
        public let bytes: Int64
        public var restored: Bool
    }
    public let id: String
    public let created: Date
    public var entries: [Entry]
}
public struct ClaudeResetResult: Encodable, Sendable {
    public var batch: ClaudeResetBatch?
    public var succeeded: [ClaudeResetTarget] = []
    public var failed: [String: String] = [:]
}

public final class ClaudeCleanup {
    private let home: String
    private let processes: () -> ProcessTable
    private let requireProcessInventory: Bool
    private let sessions: (String) -> Bool
    private let move: (URL, URL) throws -> Void
    private let lock = NSLock()
    private let fm = FileManager.default
    private let entryLimit: Int
    private var root: String { home + "/Library/Application Support/Thermo/claude-reset" }
    private struct Refusal: LocalizedError { let message: String; var errorDescription: String? { message } }
    public init(home: String = NSHomeDirectory(),
                processes: (() -> ProcessTable)? = nil,
                liveSessionCheck: ((String) -> Bool)? = nil,
                move: ((URL, URL) throws -> Void)? = nil,
                entryLimit: Int = 100_000) {
        self.home = home == "/" ? home : home.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        self.processes = processes ?? { ProcessTable.current(.init(cpu: false)) }
        self.requireProcessInventory = processes == nil
        self.sessions = liveSessionCheck ?? { !ClaudeSessions.live(AgentHome(home: $0)).isEmpty }
        self.move = move ?? { try FileManager.default.moveItem(at: $0, to: $1) }
        self.entryLimit = max(1, entryLimit)
    }
    private func fail(_ text: String) -> Refusal { Refusal(message: text) }
    private func path(_ target: ClaudeResetTarget) -> String { home + "/" + target.relativePath }
    private func info(_ path: String) throws -> stat? {
        var value = stat()
        if lstat(path, &value) == 0 { return value }
        if errno == ENOENT { return nil }
        throw fail(tr("Cannot inspect path: %1$@", path))
    }
    /// Validate every existing component, including the configured home and backup ancestors.
    private func validate(_ path: String) throws {
        guard home != "/", home.hasPrefix("/"), path == home || path.hasPrefix(home + "/"),
              "/" + path.split(separator: "/").joined(separator: "/") == path,
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw fail(tr("Path is outside the configured home")) }
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            if let st = try info(current) {
                guard (st.st_mode & S_IFMT) != S_IFLNK else { throw fail(tr("Symbolic link component: %1$@", current)) }
                if current == home || current.hasPrefix(home + "/") {
                    guard st.st_uid == getuid() else { throw fail(tr("Path is owned by another user")) }
                }
            }
        }
    }
    private func activityReason() -> String? {
        let table = processes()
        if requireProcessInventory && table.entries.isEmpty { return tr("Cannot verify running processes; reset is blocked") }
        let active = table.entries.contains { p in
            let name = p.name.lowercased()
            let exe = (p.executable ?? "").lowercased()
            return name == "claude" || name.hasPrefix("claude ") || name.hasPrefix("claude-") || name.hasPrefix("claude helper") || exe.contains("/claude.app/") || exe.contains("/claude-3p.app/") || exe.contains("/.local/share/claude/versions/") || p.argv.contains(where: {
                $0.contains("@anthropic-ai/claude-code") || ($0.hasSuffix("/cli.js") && $0.contains("/claude-code/"))
            })
        }
        if active { return tr("Quit Claude and Claude Code before resetting or restoring local data") }
        do {
            try validate(home + "/.claude/sessions")
            let sessionPath = home + "/.claude/sessions"
            if try info(sessionPath) != nil {
                let records = try fm.contentsOfDirectory(atPath: sessionPath)
                guard records.count <= entryLimit else { return tr("Session inventory exceeds its limit") }
                for name in records where name.hasSuffix(".json") {
                    try validate(sessionPath + "/" + name)
                    guard let st = try info(sessionPath + "/" + name), (st.st_mode & S_IFMT) == S_IFREG,
                          st.st_size <= 1024 * 1024 else { return tr("Session metadata cannot be safely inspected") }
                }
            }
            // Session metadata is the only content consulted; target files are never opened.
            if sessions(home) { return tr("A live Claude Code session is registered") }
        } catch { return error.localizedDescription }
        return nil
    }
    /// A bounded metadata inventory, including links themselves but never their destinations.
    private func snapshot(_ path: String) throws -> (String, Int64) {
        try validate(path)
        var hasher = SHA256(); var bytes: Int64 = 0; var count = 0
        func walk(_ p: String, _ relative: String) throws {
            count += 1
            guard count <= entryLimit, let st = try info(p) else { throw fail(tr("Metadata inventory is incomplete or exceeds its limit")) }
            let kind = st.st_mode & S_IFMT
            guard st.st_uid == getuid(), kind == S_IFREG || kind == S_IFDIR || kind == S_IFLNK else { throw fail(tr("Unsupported file type or ownership")) }
            let row = "\(relative.utf8.count):\(relative)|\(st.st_dev)|\(st.st_ino)|\(st.st_mode)|\(st.st_nlink)|\(st.st_size)|\(st.st_mtimespec.tv_sec):\(st.st_mtimespec.tv_nsec)|\(st.st_birthtimespec.tv_sec):\(st.st_birthtimespec.tv_nsec)\n"
            hasher.update(data: Data(row.utf8))
            if kind == S_IFREG { bytes += st.st_size }
            if kind == S_IFDIR {
                let names = try fm.contentsOfDirectory(atPath: p).sorted()
                for name in names { try walk(p + "/" + name, relative + "/" + name) }
                guard let after = try info(p), after.st_mtimespec.tv_sec == st.st_mtimespec.tv_sec,
                      after.st_mtimespec.tv_nsec == st.st_mtimespec.tv_nsec, after.st_ino == st.st_ino else { throw fail(tr("Directory changed during inventory")) }
            }
        }
        try walk(path, "")
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
    }
    public func scan() -> [ClaudeResetCandidate] {
        let active = activityReason()
        return ClaudeResetTarget.allCases.map { target in
            let p = path(target)
            do {
                try validate(p)
                guard try info(p) != nil else { return .init(target: target, path: p, status: .missing, reason: nil, bytes: 0, snapshot: nil) }
                let value = try snapshot(p)
                return .init(target: target, path: p, status: active == nil ? .available : .blocked, reason: active, bytes: value.1, snapshot: value.0)
            } catch { return .init(target: target, path: p, status: .blocked, reason: error.localizedDescription, bytes: 0, snapshot: nil) }
        }
    }
    private func directory(_ path: String) throws {
        try validate(path)
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try validate(path)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }
    public func backupURL(batchID: String) -> URL? {
        guard UUID(uuidString: batchID) != nil else { return nil }
        return URL(fileURLWithPath: root + "/" + batchID, isDirectory: true)
    }
    private func persist(_ batch: ClaudeResetBatch) throws {
        guard let url = backupURL(batchID: batch.id) else { throw fail(tr("Invalid batch identifier")) }
        let manifest = url.appendingPathComponent("manifest.json")
        try validate(manifest.path)
        let data = try JSONEncoder().encode(batch)
        guard data.count < 32 * 1024 * 1024 else { throw fail(tr("Backup manifest exceeds its size limit")) }
        try data.write(to: manifest, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
    }
    /// Previously persisted local batches. Invalid records are excluded, never executed.
    public func batches() -> [ClaudeResetBatch] {
        guard (try? validate(root)) != nil,
              let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        return names.compactMap { try? loadBatch(id: $0) }.sorted { $0.created > $1.created }
    }
    public struct BatchReport: Encodable, Sendable {
        public let batches: [ClaudeResetBatch]
        public let complete: Bool
        public let issues: [String]
    }
    public func batchReport() -> BatchReport {
        do {
            try validate(root)
            guard try info(root) != nil else { return .init(batches:[],complete:true,issues:[]) }
            let names = try fm.contentsOfDirectory(atPath:root).sorted()
            var batches: [ClaudeResetBatch] = [], issues: [String] = []
            if names.count > min(entryLimit,1000) { issues.append("Backup listing reached its limit.") }
            for name in names.prefix(min(entryLimit,1000)) {
                do { batches.append(try loadBatch(id:name)) }
                catch { issues.append(name + ": " + error.localizedDescription) }
            }
            return .init(batches:batches.sorted { $0.created > $1.created },complete:issues.isEmpty,issues:issues)
        } catch { return .init(batches:[],complete:false,issues:[error.localizedDescription]) }
    }
    public struct RestoreReview: Encodable, Sendable {
        public let batch: ClaudeResetBatch
        public let ready: [ClaudeResetTarget]
        public let blocked: [String:String]
    }
    public func reviewRestore(batchID: String) throws -> RestoreReview {
        let batch = try loadBatch(id:batchID)
        var ready: [ClaudeResetTarget] = [], blocked: [String:String] = [:]
        let activity = activityReason()
        for entry in batch.entries where !entry.restored {
            do {
                if let activity { throw fail(activity) }
                let original = path(entry.target), backup = backupURL(batchID:batchID)!.appendingPathComponent(entry.target.rawValue).path
                try validate(original)
                guard try info(original) == nil else { throw fail("New data exists at the original path; it will not be overwritten") }
                guard try snapshot(backup).0 == entry.snapshot, let source = try info(backup) else { throw fail("Backup changed or is missing") }
                var parent = (original as NSString).deletingLastPathComponent
                while try info(parent) == nil, parent != home { parent = (parent as NSString).deletingLastPathComponent }
                try validate(parent)
                guard let destination = try info(parent), source.st_dev == destination.st_dev else { throw fail("Restore requires a same-volume move") }
                ready.append(entry.target)
            } catch { blocked[entry.target.rawValue] = error.localizedDescription }
        }
        return .init(batch:batch,ready:ready,blocked:blocked)
    }
    public func loadBatch(id: String) throws -> ClaudeResetBatch {
        guard let url = backupURL(batchID: id) else { throw fail(tr("Invalid batch identifier")) }
        let p = url.appendingPathComponent("manifest.json").path
        try validate(p)
        guard let st = try info(p), (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1, st.st_size < 32 * 1024 * 1024 else { throw fail(tr("Invalid backup manifest")) }
        let batch = try JSONDecoder().decode(ClaudeResetBatch.self, from: Data(contentsOf: URL(fileURLWithPath: p)))
        guard batch.id == id, Set(batch.entries.map(\.target)).count == batch.entries.count else { throw fail(tr("Invalid backup manifest entries")) }
        return batch
    }
    public func reset(_ selections: [ClaudeResetCandidate]) -> ClaudeResetResult {
        lock.lock(); defer { lock.unlock() }
        var result = ClaudeResetResult()
        do {
            guard !selections.isEmpty else { return result }
            if let reason = activityReason() { throw fail(reason) }
            guard Set(selections.map(\.target)).count == selections.count else { throw fail(tr("Duplicate selections")) }
            for a in selections {
                guard a.path == path(a.target), a.status == .available, let expected = a.snapshot,
                      try snapshot(a.path).0 == expected else { throw fail(tr("Selection changed; scan again")) }
                for b in selections where a.target != b.target {
                    guard !a.path.hasPrefix(b.path + "/") else { throw fail(tr("Select either full data or individual files, not both")) }
                }
            }
            let id = UUID().uuidString
            try directory(root)
            let folder = backupURL(batchID: id)!
            try directory(folder.path)
            var batch = ClaudeResetBatch(id: id, created: Date(), entries: [])
            try persist(batch)
            result.batch = batch
            for item in selections {
                do {
                    if let reason = activityReason() { throw fail(reason) }
                    guard let expected = item.snapshot, try snapshot(item.path).0 == expected else { throw fail(tr("Selection changed; scan again")) }
                    let destination = folder.appendingPathComponent(item.target.rawValue)
                    try validate(destination.path)
                    guard try info(destination.path) == nil else { throw fail(tr("Backup destination already exists")) }
                    // Persist intent first: a crash after rename still leaves a restorable entry.
                    batch.entries.append(.init(target: item.target, snapshot: expected, bytes: item.bytes, restored: false))
                    try persist(batch)
                    if let reason = activityReason() { throw fail(reason) }
                    try validate(destination.path)
                    guard try info(destination.path) == nil, try snapshot(item.path).0 == expected else { throw fail(tr("Selection or backup destination changed")) }
                    guard let sourceInfo = try info(item.path), let backupInfo = try info(folder.path),
                          sourceInfo.st_dev == backupInfo.st_dev else { throw fail(tr("Reset requires a same-volume move")) }
                    try move(URL(fileURLWithPath: item.path), destination)
                    guard try info(item.path) == nil, try snapshot(destination.path).0 == expected else { throw fail(tr("Move could not be verified; inspect backup")) }
                    result.succeeded.append(item.target)
                } catch { result.failed[item.target.rawValue] = error.localizedDescription }
            }
            result.batch = batch
        } catch { result.failed["reset"] = error.localizedDescription }
        journal(result, action: "reset", bytes: Dictionary(selections.map { ($0.target, $0.bytes) }, uniquingKeysWith: { a, _ in a }))
        return result
    }
    public func restore(batchID: String) -> ClaudeResetResult {
        lock.lock(); defer { lock.unlock() }
        var result = ClaudeResetResult()
        do {
            if let reason = activityReason() { throw fail(reason) }
            var batch = try loadBatch(id: batchID)
            result.batch = batch
            for index in batch.entries.indices where !batch.entries[index].restored {
                let entry = batch.entries[index]
                do {
                    if let reason = activityReason() { throw fail(reason) }
                    let original = path(entry.target)
                    let backup = backupURL(batchID: batchID)!.appendingPathComponent(entry.target.rawValue)
                    try validate(original)
                    guard try info(original) == nil else { throw fail(tr("New data exists at the original path; it will not be overwritten")) }
                    guard try snapshot(backup.path).0 == entry.snapshot else { throw fail(tr("Backup changed or is missing")) }
                    let parent = (original as NSString).deletingLastPathComponent
                    try validate(parent)
                    try fm.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try validate(original)
                    if let reason = activityReason() { throw fail(reason) }
                    guard try info(original) == nil, try snapshot(backup.path).0 == entry.snapshot else { throw fail(tr("Original path or backup changed")) }
                    guard let backupInfo = try info(backup.path), let parentInfo = try info(parent),
                          backupInfo.st_dev == parentInfo.st_dev else { throw fail(tr("Restore requires a same-volume move")) }
                    try move(backup, URL(fileURLWithPath: original))
                    guard try snapshot(original).0 == entry.snapshot, try info(backup.path) == nil else { throw fail(tr("Restore could not be verified")) }
                    batch.entries[index].restored = true
                    try persist(batch)
                    result.succeeded.append(entry.target)
                } catch { result.failed[entry.target.rawValue] = error.localizedDescription }
            }
            result.batch = batch
        } catch { result.failed["restore"] = error.localizedDescription }
        journal(result, action: "restore", bytes: Dictionary((result.batch?.entries ?? []).map { ($0.target, $0.bytes) }, uniquingKeysWith: { a, _ in a }))
        return result
    }
    /// Mirrors a reset or restore into the shared operation history; resets point at their recovery record.
    private func journal(_ result: ClaudeResetResult, action: String, bytes: [ClaudeResetTarget: Int64]) {
        var items = result.succeeded.map { OperationRecord.Item(target: path($0), bytes: bytes[$0], status: "done") }
        items += result.failed.sorted { $0.key < $1.key }.map { key, why in
            OperationRecord.Item(target: ClaudeResetTarget(rawValue: key).map(path) ?? key, status: "failed", detail: why)
        }
        let undo = action == "reset" && !result.succeeded.isEmpty ? result.batch.map { OperationRecord.Undo(kind: "claudeReset", ref: $0.id) } : nil
        OperationJournal.record(OperationRecord(feature: "claudeReset", action: action, items: items, undo: undo), home: home)
    }
}
