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
        var commonIdentity: String
        var head: String
        var staleLock: String?
    }
    struct Refusal: Error, CustomStringConvertible {
        var description: String
        init(_ text: String) { description = text }
    }
    static func runGit(_ arguments: [String]) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["GIT_OPTIONAL_LOCKS"] = "0"; environment["GIT_NO_LAZY_FETCH"] = "1"
        let cancellation = ScanCancellation.current
        let result = CommandRunner.run("/usr/bin/git", arguments: ["--no-replace-objects", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0"] + arguments,
                                       environment: environment, timeout: 10, outputLimit: 4_194_304, captureError: false,
                                       cancelled: { cancellation?.isCancelled == true })
        guard result.status == 0, !result.timedOut, !result.cancelled, !result.truncated else {
            throw Refusal("Git could not completely verify the worktree; keep it")
        }
        // A path may end in spaces: remove only Git's terminating newline.
        return result.output.hasSuffix("\n") ? String(result.output.dropLast()) : result.output
    }
    static func git(_ path: String, _ arguments: [String]) throws -> String { try runGit(["-C", path] + arguments) }
    static func head(_ metadata: String) throws -> String {
        let value = try runGit(["--git-dir", metadata, "rev-parse", "--verify", "HEAD^{commit}"])
        guard [40,64].contains(value.count), value.allSatisfy({ $0.isHexDigit }) else { throw Refusal("Git could not completely verify the worktree; keep it") }
        return value
    }
    static func registeredPath(_ metadata: String) throws -> String {
        let file = metadata + "/gitdir"
        let fd = open(file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Refusal("worktree registration target could not be verified") }
        defer { close(fd) }
        var before = stat(), after = stat(), named = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= 16_384,
              let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 16_385), data.count == before.st_size,
              fstat(fd, &after) == 0, lstat(file, &named) == 0,
              AppDataReviewIdentity.text(before) == AppDataReviewIdentity.text(after),
              AppDataReviewIdentity.text(after) == AppDataReviewIdentity.text(named),
              var pointer = String(data: data, encoding: .utf8) else { throw Refusal("worktree registration target could not be verified") }
        if pointer.hasSuffix("\n") { pointer.removeLast() }
        guard pointer.hasPrefix("/"), pointer.hasSuffix("/.git"), !pointer.contains("\0"),
              !pointer.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw Refusal("worktree registration target could not be verified") }
        return physical(String(pointer.dropLast(5)))
    }
    static func verifyRetention(_ registration: Registration) throws {
        guard FS.isDirectory(registration.metadata), FS.isDirectory(registration.common),
              FileIdentity.of(registration.metadata) == registration.metadataIdentity,
              FileIdentity.of(registration.common) == registration.commonIdentity,
              try registeredPath(registration.metadata) == registration.path,
              try runGit(["--git-dir", registration.metadata, "rev-parse", "--path-format=absolute", "--git-common-dir"]) == registration.common,
              try head(registration.metadata) == registration.head else { throw Refusal("worktree Git identity or HEAD changed; scan again") }
        var graft = stat()
        let graftResult = lstat(registration.common + "/info/grafts", &graft)
        guard graftResult != 0, errno == ENOENT else { throw Refusal("worktree commit retention cannot be verified with legacy grafts; keep it") }
        // Query the common/main context only. Current/other linked HEADs and their private
        // refs disappear with registration cleanup and cannot serve as durable anchors.
        let unique = try runGit(["--git-dir", registration.common, "rev-list", "--single-worktree", "--max-count=1", registration.head, "--not", "--all"])
        guard unique.isEmpty else { throw Refusal("worktree has commits not retained by the shared repository; keep it") }
        guard try head(registration.metadata) == registration.head,
              FileIdentity.of(registration.common) == registration.commonIdentity,
              FileIdentity.of(registration.metadata) == registration.metadataIdentity else { throw Refusal("worktree Git identity or HEAD changed; scan again") }
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
        guard processes.available else { throw Refusal("could not verify processes using this worktree; keep it") }
        guard FS.exists(path + "/.git") else { return nil }
        guard !FS.isDirectory(path + "/.git") else { throw Refusal("a main repository is not a disposable worktree") }
        if processes.entries.contains(where: { $0.cwd.map { cwd in let cwd = physical(cwd); return cwd == path || cwd.hasPrefix(path + "/") } == true }) {
            throw Refusal("a process is running in this worktree")
        }
        let metadata = try git(path, ["rev-parse", "--path-format=absolute", "--git-dir"])
        let common = try git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard (metadata as NSString).deletingLastPathComponent == common + "/worktrees",
              let identity = FileIdentity.of(metadata), let commonIdentity = FileIdentity.of(common) else { throw Refusal("worktree registration could not be verified") }
        let status = try git(path, ["status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none"])
        guard status.isEmpty else { throw Refusal("worktree has uncommitted or untracked files; keep it") }
        // Submodule worktrees have additional registrations we cannot safely detach here.
        guard !FS.exists(metadata + "/modules"), !FS.exists(path + "/.gitmodules") else { throw Refusal("worktrees with submodules are kept") }
        let lock = try staleLock(metadata: metadata, path: path)
        let registration = Registration(path: path, common: common, metadata: metadata, metadataIdentity: identity,
                                        commonIdentity: commonIdentity, head: try head(metadata), staleLock: lock)
        try verifyRetention(registration)
        return registration
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
        try verifyRetention(registration)
        guard FileIdentity.of(registration.metadata) == registration.metadataIdentity else { throw Refusal("worktree metadata changed") }
        if let lock = registration.staleLock {
            guard String(data: FS.head(registration.metadata + "/locked") ?? Data(), encoding: .utf8) == lock else { throw Refusal("worktree lock changed") }
            // Recheck liveness immediately before unlocking, not just at preview time.
            guard let pidText = lock.components(separatedBy: "pid ").last?.prefix(while: { $0.isNumber }),
                  let pid = Int32(pidText), kill(pid, 0) == -1, errno == ESRCH else { throw Refusal("worktree lock holder is alive or unknown") }
            _ = try runGit(["--git-dir", registration.common, "worktree", "unlock", registration.path])
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
        try verifyRetention(registration)
        guard !FS.exists(registration.path), FileIdentity.of(registration.metadata) == registration.metadataIdentity else {
            throw Refusal("original path or registration changed; Git cleanup was skipped")
        }
        _ = try runGit(["--git-dir", registration.common, "worktree", "remove", registration.path])
        guard !FS.exists(registration.metadata) else { throw Refusal("Git registration removal could not be confirmed") }
    }
}
