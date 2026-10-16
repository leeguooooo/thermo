import Darwin
import Foundation

/// Git metadata near the sampled cwd; never executes Git, hooks, filters or config.
/// This observation does not prove which project the process is actually working on.
public struct ProcessGitContext: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case observed, noneObserved, unavailable }
    public var state: State
    public var root: String?
    public var gitDirectory: String?
    public var branch: String?
    public var commit: String?
    public var detached: Bool?
    public var queryComplete: Bool

    static var unavailable: Self { .init(state:.unavailable,queryComplete:false) }

    public static func capture(workingDirectory: String?) -> Self {
        inspect(workingDirectory:workingDirectory)
    }

    static func inspect(workingDirectory: String?, maximumDepth: Int = 64, afterRead: () -> Void = {}) -> Self {
        guard let workingDirectory,workingDirectory.hasPrefix("/"),!workingDirectory.utf8.contains(0),
              workingDirectory.utf8.count <= 4096,maximumDepth > 0,maximumDepth <= 128 else { return unavailable }
        let reader=Reader()
        do {
            var directory=try canonicalDirectory(workingDirectory)
            for _ in 0..<maximumDepth {
                try reader.directory(directory.path)
                let marker=directory.appendingPathComponent(".git")
                if let info=try reader.metadata(marker.path) {
                    let git: URL
                    if info.st_mode & S_IFMT == S_IFDIR { git=marker }
                    else if info.st_mode & S_IFMT == S_IFREG,let text=try reader.text(marker.path,limit:4096),
                            let value=singleLine(text),value.hasPrefix("gitdir: "),value.count > 8 {
                        git=try resolve(String(value.dropFirst(8)),relativeTo:directory)
                    } else { throw Failure() }
                    try reader.directory(git.path)
                    guard let head=try reader.text(git.appendingPathComponent("HEAD").path,limit:4096).flatMap(singleLine) else { throw Failure() }
                    var result=Self(state:.observed,root:ProcessExplanation.displayed(directory.path),
                                    gitDirectory:ProcessExplanation.displayed(git.path),queryComplete:true)
                    if objectID(head) { result.commit=head.lowercased();result.detached=true }
                    else if head.hasPrefix("ref: refs/heads/") {
                        let ref=String(head.dropFirst(5))
                        guard validBranchRef(ref) else { throw Failure() }
                        result.branch=ProcessExplanation.displayed(String(ref.dropFirst(11)));result.detached=false
                        var common=git
                        if let text=try reader.text(git.appendingPathComponent("commondir").path,limit:4096) {
                            guard let value=singleLine(text),!value.isEmpty else { throw Failure() }
                            common=try resolve(value,relativeTo:git);try reader.directory(common.path)
                        }
                        if let text=try reader.text(common.appendingPathComponent(ref).path,limit:4096) {
                            guard let value=singleLine(text),objectID(value) else { throw Failure() };result.commit=value.lowercased()
                        } else if let packed=try reader.text(common.appendingPathComponent("packed-refs").path,limit:1_048_576) {
                            let matching=packed.split(separator:"\n").filter { !$0.hasPrefix("#") && !$0.hasPrefix("^") }.compactMap { line -> String? in
                                let parts=line.split(separator:" ",omittingEmptySubsequences:false)
                                guard parts.count == 2,parts[1] == ref else { return nil }
                                return String(parts[0])
                            }
                            guard matching.count <= 1,matching.allSatisfy(objectID) else { throw Failure() }
                            result.commit=matching.first?.lowercased()
                        }
                        // Unborn branches, reftable and missing/unreadable refs cannot prove a commit.
                        if result.commit == nil { result.queryComplete=false }
                    } else { throw Failure() }
                    afterRead();guard reader.unchanged() else { return unavailable };return result
                }
                let parent=directory.deletingLastPathComponent()
                if parent.path == directory.path {
                    afterRead();guard reader.unchanged() else { return unavailable }
                    return .init(state:.noneObserved,queryComplete:true)
                }
                directory=parent
            }
        } catch { return unavailable }
        return unavailable
    }

    private static func canonicalDirectory(_ path: String) throws -> URL {
        guard let resolved=realpath(path,nil) else { throw Failure() };defer { free(resolved) }
        return URL(fileURLWithPath:String(cString:resolved))
    }
    private static func resolve(_ value: String, relativeTo directory: URL) throws -> URL {
        try canonicalDirectory(value.hasPrefix("/") ? value : directory.appendingPathComponent(value).path)
    }
    private static func singleLine(_ value: String) -> String? {
        var text=value
        if text.hasSuffix("\n") { text.removeLast() }
        guard !text.isEmpty,!text.unicodeScalars.contains(where:{ CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }
    private static func objectID(_ value: String) -> Bool {
        (value.utf8.count == 40 || value.utf8.count == 64) && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    private static func validBranchRef(_ value: String) -> Bool {
        value.hasPrefix("refs/heads/") && value.count > 11 && value.utf8.count <= 1024 &&
        !value.contains("..") && !value.contains("@{") && !value.hasSuffix(".") &&
        !value.unicodeScalars.contains { $0.value < 33 || $0.value == 127 || "~^:?*[\\".unicodeScalars.contains($0) } &&
        value.split(separator:"/",omittingEmptySubsequences:false).allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }
    }
    private struct Failure: Error {}
    private final class Reader {
        private var observations: [(String,stat?)] = []
        private var directories: [Int32] = []
        private let started=DispatchTime.now().uptimeNanoseconds
        deinit { for fd in directories { close(fd) } }
        private func budget() throws {
            guard DispatchTime.now().uptimeNanoseconds-started < 500_000_000 else { throw Failure() }
        }
        func metadata(_ path: String) throws -> stat? {
            try budget();guard path.utf8.count <= 8192 else { throw Failure() }
            var info=stat()
            if lstat(path,&info) == 0 { observations.append((path,info));return info }
            guard errno == ENOENT else { throw Failure() }
            observations.append((path,nil));return nil
        }
        func directory(_ path: String) throws {
            guard let info=try metadata(path),info.st_mode & S_IFMT == S_IFDIR else { throw Failure() }
            let fd=open(path,O_RDONLY|O_CLOEXEC|O_NONBLOCK|O_NOFOLLOW|O_DIRECTORY)
            guard fd >= 0 else { throw Failure() }
            var opened=stat()
            guard fstat(fd,&opened) == 0,Self.same(info,opened) else { close(fd);throw Failure() }
            directories.append(fd)
        }
        func text(_ path: String, limit: Int) throws -> String? {
            guard let named=try metadata(path) else { return nil }
            guard named.st_mode & S_IFMT == S_IFREG,named.st_size >= 0,named.st_size <= limit else { throw Failure() }
            let fd=open(path,O_RDONLY|O_CLOEXEC|O_NONBLOCK|O_NOFOLLOW)
            guard fd >= 0 else { throw Failure() };defer { close(fd) }
            var before=stat(),after=stat()
            guard fstat(fd,&before) == 0,Self.same(before,named) else { throw Failure() }
            var bytes=[UInt8](repeating:0,count:limit+1),count=0
            while count < bytes.count {
                try budget()
                let n=bytes.withUnsafeMutableBytes { read(fd,$0.baseAddress!.advanced(by:count),$0.count-count) }
                if n < 0 { if errno == EINTR { continue };throw Failure() }
                if n == 0 { break };count+=n
            }
            guard count <= limit,fstat(fd,&after) == 0,Self.same(before,after),
                  let text=String(bytes:bytes.prefix(count),encoding:.utf8),!text.utf8.contains(0) else { throw Failure() }
            return text
        }
        func unchanged() -> Bool {
            guard (try? budget()) != nil else { return false }
            return observations.allSatisfy { path,old in
                guard (try? budget()) != nil else { return false }
                var now=stat()
                if lstat(path,&now) == 0 { return old.map { Self.same($0,now) } ?? false }
                return old == nil && errno == ENOENT
            }
        }
        private static func same(_ a: stat,_ b: stat) -> Bool {
            guard a.st_dev == b.st_dev,a.st_ino == b.st_ino,a.st_mode == b.st_mode else { return false }
            // Keep directory descriptors open to prevent inode reuse. Changes to
            // unrelated siblings do not change the observed marker or HEAD.
            if a.st_mode & S_IFMT == S_IFDIR { return true }
            return a.st_size == b.st_size &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
        }
    }
}
