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
            guard let data = codegraphDaemonData(url),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let root = o["root"] as? String, let pid = (o["pid"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
            return CodegraphDaemon(root: root, pid: pid, version: o["version"] as? String ?? "")
        }
    }

    /// Bound I/O before parsing. Check the opened descriptor so links to ordinary records keep
    /// working, while non-regular targets are skipped without waiting for a writer.
    private static func codegraphDaemonData(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let limit = 64 * 1024
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size <= Int64(limit) else { return nil }
        // The extra byte also detects a file growing beyond the cap after fstat.
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
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

    /// The codegraph on the agents' PATH and its version, when it answers.
    private func installedCodegraph() -> (path: String, version: String)? {
        guard let path = env.resolve("codegraph"),
              let out = env.run(path, ["--version"])?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty else { return nil }
        return (path, out.split(separator: " ").last.map(String.init) ?? out)
    }

    /// Code indexes and agent databases with large write-ahead logs, and codegraph background
    /// processes still running a version with the growth bug. Each affected project becomes an item
    /// whose fix upgrades codegraph when the installed one has the bug, then gracefully stops the
    /// project's background process so it can checkpoint as it exits; the next use starts the new version.
    mutating func checkAgentDatabases() {
        guard !env.cancelled() else { return }
        let daemons = Self.codegraphDaemons(in: env.url(".codegraph/daemons"))
        let live = daemons.filter(running)
        var installed: (path: String, version: String)??
        func codegraph() -> (path: String, version: String)? {
            if installed == nil { installed = .some(installedCodegraph()) }
            return installed!
        }

        // Every project codegraph runs in, or that Claude Code has opened.
        var roots = daemons.map(\.root)
        if let cj = env.json(env.url(".claude.json")) as? [String: Any], let projects = cj["projects"] as? [String: Any] {
            roots += projects.keys.sorted()
        }
        var seen = Set<String>()
        for root in roots where seen.insert(root).inserted {
            guard !env.cancelled() else { return }
            let stuck = Self.stuckLog(root + "/.codegraph/codegraph.db")
            let here = live.filter { $0.root == root }
            let buggy = here.filter { Self.codegraphHasLogBug($0.version) }
            guard stuck != nil || !buggy.isEmpty else { continue }

            // A stuck log needs every process on it to exit; an old one only needs replacing.
            let stopping = stuck != nil ? here : buggy
            var steps: [Step] = []
            if !buggy.isEmpty, let cg = codegraph(), Self.codegraphHasLogBug(cg.version) {
                steps.append(.run(tool: cg.path, args: ["upgrade"], cwd: nil))
            }
            for d in stopping {
                guard let args = env.run("/bin/ps", ["-o", "args=", "-p", String(d.pid)])?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !args.isEmpty else { continue }
                steps.append(.kill(pid: d.pid, args: args))
            }
            let source = env.short(stuck.map { $0.database + "-wal" } ?? env.url(".codegraph/daemons").path)
            item(.processes, agent: "shared", id: "codegraph|" + root, name: "codegraph · " + env.short(root),
                 detail: here.map { "pid \($0.pid) · \($0.version)" }.joined(separator: ", "), source: source)
            defer { currentItem = nil }

            if let stuck {
                let fix = buggy.isEmpty
                    ? tr("check whether the log keeps growing while the project is idle; size alone does not prove checkpoint failure. If needed, stop codegraph gracefully and recheck. Never delete the -wal file: it may contain uncheckpointed data")
                    : tr("codegraph %1$@ predates the WAL growth fix in 1.6.1; upgrade and restart it gracefully, then recheck the log. Never delete the -wal file: it may contain uncheckpointed data", buggy[0].version)
                add(Finding(stuck.logBytes >= Self.stuckLogSevere ? .error : .warning, .processes, agent: "shared", subject: "codegraph",
                            tr("the code index of %1$@ has a %2$@ write-ahead log next to a %3$@ index; this snapshot cannot establish whether the log is growing or checkpointing is blocked",
                               env.short(root), Self.bytes(stuck.logBytes), Self.bytes(stuck.databaseBytes)),
                            fix: fix, source: source))
            } else {
                add(Finding(.warning, .processes, agent: "shared", subject: "codegraph",
                            tr("a codegraph background process for %1$@ still runs %2$@, whose index log can grow until the disk is full (fixed in 1.6.1)",
                               env.short(root), buggy[0].version),
                            fix: tr("run codegraph upgrade if needed, then stop process %1$@; it starts again on the new version when next used",
                                    buggy.map { String($0.pid) }.joined(separator: ", ")),
                            source: source))
            }
            if steps.contains(where: { if case .kill = $0 { return true }; return false }) {
                let upgrades = steps.contains { if case .run = $0 { return true }; return false }
                offer(.fix, upgrades ? tr("Upgrade codegraph and restart it") : tr("Restart codegraph"),
                      upgrades ? tr("Upgrades codegraph to the version with the WAL growth fix, then gracefully stops this project's old background process; the next query starts the new one.")
                               : tr("Gracefully stops this project's codegraph background process so it can checkpoint as it exits; the next query starts it again."),
                      steps, bulk: !upgrades)
            }
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
