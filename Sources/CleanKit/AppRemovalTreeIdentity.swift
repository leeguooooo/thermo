import CryptoKit
import Darwin
import Foundation

/// A bounded metadata snapshot for an app bundle or associated directory selected for removal. It includes
/// every directory entry without following links or reading application payloads.
/// This detects ordinary writes through ctime; it is not a content or signature seal.
public struct AppRemovalTreeIdentity: Codable, Sendable, Equatable {
    var digest: String
    var entries: Int

    struct Observation: Sendable, Equatable {
        let identity: AppRemovalTreeIdentity
        let newestTimestamp: TimeInterval
    }

    static func capture(_ path: String, maxEntries: Int = 250_000, maxDepth: Int = 128,
                        timeout: TimeInterval = 10) -> Self? {
        observe(path, maxEntries: maxEntries, maxDepth: maxDepth, timeout: timeout)?.identity
    }

    /// Activity comes from the same complete, twice-verified metadata walk. A
    /// size walk's newest timestamp alone cannot seal a residual-data review.
    static func observe(_ path: String, maxEntries: Int = 250_000, maxDepth: Int = 128,
                        timeout: TimeInterval = 10) -> Observation? {
        enum Failure: Error { case unknown }
        let unknown = Failure.unknown
        let cancellation = ScanCancellation.current
        let started = ProcessInfo.processInfo.systemUptime
        var root = stat()
        guard path.hasPrefix("/"), maxEntries > 0, maxDepth >= 0, timeout > 0,
              lstat(path, &root) == 0, root.st_mode & S_IFMT == S_IFDIR else { return nil }
        let expectedRoot = AppDataReviewIdentity.text(root)
        func budget(_ count: Int, depth: Int) throws {
            guard count <= maxEntries, depth <= maxDepth, cancellation?.isCancelled != true,
                  ProcessInfo.processInfo.systemUptime - started < timeout else { throw unknown }
        }
        func pass() throws -> Observation {
            var hash = SHA256()
            var count = 0
            var newest = -TimeInterval.infinity
            func record(_ relative: String, _ info: stat) throws {
                count += 1
                try budget(count, depth: 0)
                let metadata = AppDataReviewIdentity.text(info)
                hash.update(data: Data("\(relative.utf8.count):\(relative)\n\(metadata)\n".utf8))
                newest = max(newest,
                    TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000,
                    TimeInterval(info.st_ctimespec.tv_sec) + TimeInterval(info.st_ctimespec.tv_nsec) / 1_000_000_000)
            }
            // Takes ownership of fd, including on failure.
            func directory(_ fd: Int32, relative: String, expected: stat, depth: Int) throws {
                guard let stream = fdopendir(fd) else { close(fd); throw unknown }
                defer { closedir(stream) }
                try budget(count, depth: depth)
                var opened = stat()
                guard fstat(fd, &opened) == 0,
                      AppDataReviewIdentity.text(opened) == AppDataReviewIdentity.text(expected),
                      opened.st_dev == root.st_dev else { throw unknown }
                try record(relative, opened)
                var names: [String] = []
                while true {
                    try budget(count + names.count, depth: depth)
                    errno = 0
                    guard let entry = readdir(stream) else {
                        guard errno == 0 else { throw unknown }
                        break
                    }
                    let bytes = withUnsafeBytes(of: entry.pointee.d_name) {
                        Array($0.prefix(Int(entry.pointee.d_namlen)))
                    }
                    guard let name = String(bytes: bytes, encoding: .utf8) else { throw unknown }
                    if name == "." || name == ".." { continue }
                    names.append(name)
                }
                for name in names.sorted() {
                    try budget(count + 1, depth: depth + 1)
                    var before = stat(), after = stat()
                    guard fstatat(fd, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
                          before.st_dev == root.st_dev else { throw unknown }
                    let child = relative.isEmpty ? name : relative + "/" + name
                    switch before.st_mode & S_IFMT {
                    case S_IFDIR:
                        let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                        guard next >= 0 else { throw unknown }
                        try directory(next, relative: child, expected: before, depth: depth + 1)
                    case S_IFREG, S_IFLNK:
                        try record(child, before)
                        // Link contents are not followed; ctime and identity cover replacement.
                    default: throw unknown
                    }
                    guard fstatat(fd, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
                          AppDataReviewIdentity.text(before) == AppDataReviewIdentity.text(after) else { throw unknown }
                }
                var after = stat()
                guard fstat(fd, &after) == 0,
                      AppDataReviewIdentity.text(opened) == AppDataReviewIdentity.text(after) else { throw unknown }
            }
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw unknown }
            try directory(fd, relative: "", expected: root, depth: 0)
            var named = stat()
            guard lstat(path, &named) == 0, AppDataReviewIdentity.text(named) == expectedRoot else { throw unknown }
            guard newest.isFinite else { throw unknown }
            return Observation(identity: Self(digest: hash.finalize().map { String(format: "%02x", $0) }.joined(), entries: count),
                               newestTimestamp: newest)
        }
        do {
            let first = try pass()
            // A second walk detects changes to earlier subtrees during the first.
            guard try pass() == first else { return nil }
            return first
        } catch { return nil }
    }
}
