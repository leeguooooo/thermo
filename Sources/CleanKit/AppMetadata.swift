import AgentCore
import CryptoKit
import Darwin
import Foundation

/// Bounded regular-file snapshots for app metadata. This is not a seal of the whole bundle.
enum AppMetadata {
    static let maxBytes = 1_048_576
    struct Snapshot {
        let info: [String: Any]
        let identity: String
        let digest: String
    }
    static func dictionary(_ path: String) -> [String: Any]? { read(path)?.info }
    /// A linked target may supply display fields, never a trusted bundle identity.
    static func linkedDisplayDictionary(_ path: String) -> [String: Any]? {
        var link = stat()
        guard lstat(path, &link) == 0, link.st_mode & S_IFMT == S_IFLNK else { return nil }
        let identity = AppDataReviewIdentity.text(link)
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard target != path, let snapshot = read(target), AppDataReviewIdentity.of(path) == identity,
              URL(fileURLWithPath: path).resolvingSymlinksInPath().path == target else { return nil }
        return snapshot.info
    }
    static func read(_ path: String, afterRead: () -> Void = {}) -> Snapshot? {
        var namedBefore = stat()
        guard lstat(path, &namedBefore) == 0, namedBefore.st_mode & S_IFMT == S_IFREG,
              namedBefore.st_size > 0, namedBefore.st_size <= maxBytes else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, AppDataReviewIdentity.text(before) == AppDataReviewIdentity.text(namedBefore),
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= maxBytes else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count <= maxBytes {
            if ScanCancellation.current?.isCancelled == true { return nil }
            let remaining = maxBytes + 1 - data.count
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, remaining)) }
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
        afterRead()
        var after = stat(), named = stat()
        guard data.count == before.st_size, data.count <= maxBytes,
              fstat(fd, &after) == 0, lstat(path, &named) == 0,
              AppDataReviewIdentity.text(before) == AppDataReviewIdentity.text(after),
              AppDataReviewIdentity.text(after) == AppDataReviewIdentity.text(named),
              ScanCancellation.current?.isCancelled != true,
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        return Snapshot(info: info, identity: AppDataReviewIdentity.text(after),
                        digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}
