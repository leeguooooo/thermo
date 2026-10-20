import Darwin
import Foundation
import ThermoL10n

/// A large SQLite write-ahead log. File size is an observation, not evidence of checkpoint
/// failure or continued growth: SQLite may retain and reuse a checkpointed WAL.
struct StuckLog: Equatable {
    var database: String
    var databaseBytes: Int64
    var logBytes: Int64
}

/// One codegraph background process, as codegraph records it in `~/.codegraph/daemons`.
struct CodegraphDaemon: Equatable {
    var root: String
    var pid: Int32
    var version: String
}

extension ConfigChecks {
    static let stuckLogFloor: Int64 = 1 << 30
    static let stuckLogSevere: Int64 = 8 << 30
    /// codegraph 1.6.1 checkpoints its log under load (colbymchenry/codegraph#1539, fixed by #1751).
    static let codegraphLogFix = [1, 6, 1]

    /// A log at least 1 GB and bigger than its database; nil below this reporting threshold.
    /// This metadata-only check does not open SQLite or inspect checkpoint progress.
    static func stuckLog(_ database: String) -> StuckLog? {
        var db = stat(), log = stat()
        guard lstat(database + "-wal", &log) == 0, log.st_mode & S_IFMT == S_IFREG,
              Int64(log.st_size) >= stuckLogFloor else { return nil }
        let dbBytes = lstat(database, &db) == 0 && db.st_mode & S_IFMT == S_IFREG ? Int64(db.st_size) : 0
        guard Int64(log.st_size) > dbBytes else { return nil }
        return StuckLog(database: database, databaseBytes: dbBytes, logBytes: Int64(log.st_size))
    }

    static func codegraphDaemons(in dir: URL) -> [CodegraphDaemon] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap { url in
            guard let data = try? Data(contentsOf: url), data.count <= 64 * 1024,
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let root = o["root"] as? String, let pid = (o["pid"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
            return CodegraphDaemon(root: root, pid: pid, version: o["version"] as? String ?? "")
        }
    }

    /// Versions before the one that fixed the growing log; unknown versions are not blamed.
    static func codegraphHasLogBug(_ version: String) -> Bool {
        let parts = version.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) }
        guard parts.count >= 3, parts.allSatisfy({ $0 != nil }) else { return false }
        return parts.prefix(3).map { $0! }.lexicographicallyPrecedes(codegraphLogFix)
    }

    private static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    /// A daemon record whose process still runs codegraph (pids are reused). An upgrade deletes the
    /// old version's node, and a process whose program is gone has no path: its name still tells.
    private func running(_ d: CodegraphDaemon) -> Bool {
        guard kill(d.pid, 0) == 0 || errno == EPERM else { return false }
        var name = [CChar](repeating: 0, count: 256)
        guard let program = (env.executablePath(d.pid) ?? (proc_name(d.pid, &name, UInt32(name.count)) > 0 ? String(cString: name) : nil))?.lowercased()
        else { return false }
        return program.contains("node") || program.contains("codegraph")
    }

    /// Code indexes and agent databases with large write-ahead logs, and
    /// codegraph background processes still running a version with that bug.
    mutating func checkAgentDatabases() {
        guard !env.cancelled() else { return }
        let daemons = Self.codegraphDaemons(in: env.url(".codegraph/daemons"))
        let live = daemons.filter(running)
        let codegraphItem = items.filter { $0.area == .mcp && $0.name.lowercased() == "codegraph" }.map(\.id)
        let codegraphFinding = { (f: Finding) -> Finding in
            var f = f
            if codegraphItem.count == 1 { f.item = codegraphItem[0] }
            return f
        }

        // Every project codegraph runs in, or that Claude Code has opened.
        var roots = daemons.map(\.root)
        if let cj = env.json(env.url(".claude.json")) as? [String: Any], let projects = cj["projects"] as? [String: Any] {
            roots += projects.keys.sorted()
        }
        var seen = Set<String>()
        for root in roots where seen.insert(root).inserted {
            guard !env.cancelled() else { return }
            guard let stuck = Self.stuckLog(root + "/.codegraph/codegraph.db") else { continue }
            let buggy = live.filter { $0.root == root && Self.codegraphHasLogBug($0.version) }
            let fix = buggy.isEmpty
                ? tr("check whether the log keeps growing while the project is idle; size alone does not prove checkpoint failure. If needed, stop codegraph gracefully and recheck. Never delete the -wal file: it may contain uncheckpointed data")
                : tr("codegraph %1$@ predates the WAL growth fix in 1.6.1; upgrade and restart it gracefully, then recheck the log. Never delete the -wal file: it may contain uncheckpointed data", buggy[0].version)
            findings.append(codegraphFinding(Finding(stuck.logBytes >= Self.stuckLogSevere ? .error : .warning, .mcp, agent: "shared", subject: "codegraph",
                                     tr("the code index of %1$@ has a %2$@ write-ahead log next to a %3$@ index; this snapshot cannot establish whether the log is growing or checkpointing is blocked",
                                        env.short(root), Self.bytes(stuck.logBytes), Self.bytes(stuck.databaseBytes)),
                                     fix: fix, source: env.short(stuck.database + "-wal"))))
        }

        // An old daemon keeps the bug after codegraph itself is upgraded.
        for d in live where Self.codegraphHasLogBug(d.version) && Self.stuckLog(d.root + "/.codegraph/codegraph.db") == nil {
            findings.append(codegraphFinding(Finding(.warning, .mcp, agent: "shared", subject: "codegraph",
                                     tr("a codegraph background process for %1$@ still runs %2$@, whose index log can grow until the disk is full (fixed in 1.6.1)",
                                        env.short(d.root), d.version),
                                     fix: tr("run codegraph upgrade if needed, then stop process %1$@; it starts again on the new version when next used", String(d.pid)),
                                     source: env.short(env.url(".codegraph/daemons").path))))
        }

        // Codex keeps its threads and state in SQLite under ~/.codex.
        let codex = env.url(".codex")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: codex.path)) ?? []
        for name in names.sorted() where name.hasSuffix(".sqlite") {
            guard let stuck = Self.stuckLog(codex.appendingPathComponent(name).path) else { continue }
            findings.append(Finding(stuck.logBytes >= Self.stuckLogSevere ? .error : .warning, .processes, agent: "codex", subject: name,
                                    tr("Codex database %1$@ has a %2$@ write-ahead log next to %3$@ of data; this snapshot cannot establish whether the log is growing or checkpointing is blocked",
                                       name, Self.bytes(stuck.logBytes), Self.bytes(stuck.databaseBytes)),
                                    fix: tr("check whether the log keeps growing while Codex is idle; size alone does not prove checkpoint failure. If needed, quit Codex sessions and the app gracefully, then recheck. Never delete the -wal file"),
                                    source: env.short(stuck.database + "-wal")))
        }
    }
}
