import AgentCore
import Darwin
import Foundation

/// Review and repair only absent agent worktrees in one explicitly selected repository.
public enum WorktreeRegistrationRepair {
    public struct Entry: Codable, Sendable {
        public var path: String
        public var metadata: String
        public var metadataIdentity: String
        public var blocked: String?
    }
    public struct Result: Codable, Sendable {
        public var path: String
        public var backup: String?
        public var error: String?
    }
    public static func inspect(repo: String, home: String = NSHomeDirectory()) throws -> [Entry] {
        let repo = WorktreeCleanup.physical(repo)
        guard repo.hasPrefix(WorktreeCleanup.physical(home) + "/") else { throw WorktreeCleanup.Refusal("repository is outside the selected home") }
        let common = try WorktreeCleanup.git(repo, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard common.hasPrefix(WorktreeCleanup.physical(home) + "/") else { throw WorktreeCleanup.Refusal("Git metadata is outside the selected home") }
        let prefixes = [repo + "/.claude/worktrees/", repo + "/.codex/worktrees/", repo + "/.worktrees/"]
        var result: [Entry] = []
        for metadata in FS.children(common + "/worktrees") where FS.isDirectory(metadata) {
            guard let bytes = FS.head(metadata + "/gitdir", limit: 4096), let pointer = String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .newlines),
                  pointer.hasSuffix("/.git") else { continue }
            let rawPath = String(pointer.dropLast(5))
            guard !rawPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { continue }
            let path = WorktreeCleanup.physical(rawPath)
            guard prefixes.contains(where: { path.hasPrefix($0) }), !FS.exists(path), let identity = FileIdentity.of(metadata) else { continue }
            var blocked: String?
            do { _ = try WorktreeCleanup.staleLock(metadata: metadata, path: path) }
            catch { blocked = String(describing: error) }
            var st = stat()
            if lstat(metadata, &st) != 0 || st.st_uid != getuid() { blocked = "registration is not owned by this user" }
            result.append(Entry(path: path, metadata: metadata, metadataIdentity: identity, blocked: blocked))
        }
        return result.sorted { $0.path < $1.path }
    }
    public static func repair(repo: String, entries: [Entry], home: String = NSHomeDirectory()) -> [Result] {
        entries.map { reviewed in
            var result = Result(path: reviewed.path)
            do {
                // Re-discover provenance and lock state after review; paths and ids are not trusted input.
                guard let current = try inspect(repo: repo, home: home).first(where: { $0.path == reviewed.path }),
                      current.blocked == nil, current.metadata == reviewed.metadata,
                      current.metadataIdentity == reviewed.metadataIdentity else { throw WorktreeCleanup.Refusal("registration changed, is locked, or the worktree exists") }
                guard let open = OpenFiles.current(), open.holder(of: current.metadata) == nil else { throw WorktreeCleanup.Refusal("registration may still be in use") }
                let commonDir = ((current.metadata as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
                let registration = WorktreeCleanup.Registration(path: current.path, common: commonDir, metadata: current.metadata,
                                                                 metadataIdentity: current.metadataIdentity,
                                                                 staleLock: try WorktreeCleanup.staleLock(metadata: current.metadata, path: current.path))
                let folder = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Thermo/worktree-registration-backups")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let backup = folder.appendingPathComponent(UUID().uuidString)
                try FileManager.default.copyItem(atPath: current.metadata, toPath: backup.path)
                result.backup = backup.path
                try WorktreeCleanup.unlock(registration)
                try WorktreeCleanup.unregister(registration)
            } catch { result.error = String(describing: error) }
            return result
        }
    }
}
