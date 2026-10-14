import AgentCore
import Darwin
import Foundation

/// Git metadata is managed by Git, one selected worktree at a time. No global prune/force.
enum WorktreeCleanup {
    struct Registration {
        var path: String
        var common: String
        var metadata: String
        var metadataIdentity: String
        var staleLock: String?
    }
    struct Refusal: Error, CustomStringConvertible {
        var description: String
        init(_ text: String) { description = text }
    }
    static func git(_ path: String, _ arguments: [String]) throws -> String {
        let (status, output) = Shell.exec(["git", "-C", path] + arguments, timeout: 10)
        guard status == 0 else { throw Refusal(output.isEmpty ? "Git could not verify the worktree" : output) }
        return output
    }
    static func physical(_ path: String) -> String {
        var ancestor = path
        var suffix: [String] = []
        while true {
            if let resolved = realpath(ancestor, nil) {
                defer { free(resolved) }
                return String(cString: resolved) + (suffix.isEmpty ? "" : "/" + suffix.reversed().joined(separator: "/"))
            }
            guard ancestor.hasPrefix("/"), ancestor != "/" else { return path }
            suffix.append((ancestor as NSString).lastPathComponent)
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
    }
    static func registration(_ rawPath: String, processes: ProcessTable) throws -> Registration? {
        let path = physical(rawPath)
        guard FS.exists(path + "/.git") else { return nil }
        guard !FS.isDirectory(path + "/.git") else { throw Refusal("a main repository is not a disposable worktree") }
        if processes.entries.contains(where: { $0.cwd.map { cwd in let cwd = physical(cwd); return cwd == path || cwd.hasPrefix(path + "/") } == true }) {
            throw Refusal("a process is running in this worktree")
        }
        let metadata = try git(path, ["rev-parse", "--path-format=absolute", "--git-dir"])
        let common = try git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard (metadata as NSString).deletingLastPathComponent == common + "/worktrees",
              let identity = FileIdentity.of(metadata) else { throw Refusal("worktree registration could not be verified") }
        let status = try git(path, ["status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none"])
        guard status.isEmpty else { throw Refusal("worktree has uncommitted or untracked files; keep it") }
        // Submodule worktrees have additional registrations we cannot safely detach here.
        guard !FS.exists(metadata + "/modules"), !FS.exists(path + "/.gitmodules") else { throw Refusal("worktrees with submodules are kept") }
        let lock = try staleLock(metadata: metadata, path: path)
        return Registration(path: path, common: common, metadata: metadata, metadataIdentity: identity, staleLock: lock)
    }
    static func staleLock(metadata: String, path: String) throws -> String? {
        var lock: String?
        let lockPath = metadata + "/locked"
        if FS.exists(lockPath) {
            var st = stat()
            guard lstat(lockPath, &st) == 0, st.st_uid == getuid(), (st.st_mode & S_IFMT) == S_IFREG,
                  let data = FS.head(lockPath, limit: 4096), let reason = String(data: data, encoding: .utf8),
                  let regex = try? NSRegularExpression(pattern: "^claude agent (agent-[a-zA-Z0-9-]+) \\(pid ([0-9]+)(?:[, )])"),
                  let match = regex.firstMatch(in: reason, range: NSRange(reason.startIndex..., in: reason)),
                  let nameRange = Range(match.range(at: 1), in: reason), let pidRange = Range(match.range(at: 2), in: reason),
                  String(reason[nameRange]) == (path as NSString).lastPathComponent,
                  let pid = Int32(reason[pidRange]), pid > 1, kill(pid, 0) == -1, errno == ESRCH else {
                throw Refusal("locked worktree: lock ownership or exited holder could not be proven")
            }
            lock = reason
        }
        return lock
    }

    static func unlock(_ registration: Registration) throws {
        guard FileIdentity.of(registration.metadata) == registration.metadataIdentity else { throw Refusal("worktree metadata changed") }
        if let lock = registration.staleLock {
            guard String(data: FS.head(registration.metadata + "/locked") ?? Data(), encoding: .utf8) == lock else { throw Refusal("worktree lock changed") }
            // Recheck liveness immediately before unlocking, not just at preview time.
            guard let pidText = lock.components(separatedBy: "pid ").last?.prefix(while: { $0.isNumber }),
                  let pid = Int32(pidText), kill(pid, 0) == -1, errno == ESRCH else { throw Refusal("worktree lock holder is alive or unknown") }
            let (status, output) = Shell.exec(["git", "--git-dir", registration.common, "worktree", "unlock", registration.path], timeout: 10)
            guard status == 0 else { throw Refusal(output.isEmpty ? "Git unlock failed" : output) }
        }
    }
    static func prepare(_ registration: Registration) throws -> String {
        try unlock(registration)
        let name = ".thermo-worktree-registration-" + UUID().uuidString
        let backup = registration.path + "/" + name
        // Preserve index/HEAD/logs with the recoverable checkout before Git unregisters it.
        try FileManager.default.copyItem(atPath: registration.metadata, toPath: backup)
        return name
    }
    static func remove(_ registration: Registration) throws {
        try unlock(registration)
        _ = try git(registration.path, ["worktree", "remove", registration.path])
        guard !FS.exists(registration.path), !FS.exists(registration.metadata) else { throw Refusal("Git removal could not be confirmed") }
    }
    static func unregister(_ registration: Registration) throws {
        guard !FS.exists(registration.path), FileIdentity.of(registration.metadata) == registration.metadataIdentity else {
            throw Refusal("original path or registration changed; Git cleanup was skipped")
        }
        let (status, output) = Shell.exec(["git", "--git-dir", registration.common, "worktree", "remove", registration.path], timeout: 30)
        guard status == 0, !FS.exists(registration.metadata) else {
            throw Refusal(output.isEmpty ? "Git registration removal could not be confirmed" : output)
        }
    }
}
