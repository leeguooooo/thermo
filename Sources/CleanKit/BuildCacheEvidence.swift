import Darwin
import Foundation

/// The declaration or layout observed when a cache was offered for review.
public enum BuildCacheEvidence: String, Codable, Equatable, Sendable {
    case cacheDirectoryTag, xcodeIntermediates, xcodeModules, xcodeCompilation

    static func capture(_ path: String) -> Self? {
        let root = openDirectory(path)
        guard root >= 0 else { return nil }
        defer { close(root) }
        if validTag(root) { return .cacheDirectoryTag }
        let name = (path as NSString).lastPathComponent
        if name == "Intermediates.noindex" { return .xcodeIntermediates }
        if name == "ModuleCache.noindex" { return .xcodeModules }
        if name == "CompilationCache.noindex" { return .xcodeCompilation }
        // A generic output can contain both caches and finished products. Layout
        // alone identifies its cache children, not the entire output directory.
        if ["build", "dist", "out", "coverage"].contains(name.lowercased()) { return nil }
        if directory(root, ["Build", "Intermediates.noindex"]) { return .xcodeIntermediates }
        if directory(root, ["ModuleCache.noindex"]) { return .xcodeModules }
        if directory(root, ["CompilationCache.noindex"]) { return .xcodeCompilation }
        return nil
    }

    private static func openDirectory(_ path: String) -> Int32 {
        guard path.hasPrefix("/") else { return -1 }
        var physical = path
        // These are macOS system spellings, not project-controlled aliases.
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            physical = "/private" + path; break
        }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        var fd = open("/", flags)
        guard fd >= 0 else { return -1 }
        for component in physical.split(separator: "/") {
            guard component != ".", component != ".." else { close(fd); return -1 }
            let next = openat(fd, String(component), flags)
            close(fd)
            guard next >= 0 else { return -1 }
            fd = next
        }
        return fd
    }

    private static func directory(_ root: Int32, _ components: [String]) -> Bool {
        var parent = root
        var owned: [Int32] = []
        defer { for fd in owned.reversed() { close(fd) } }
        for component in components {
            let fd = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return false }
            owned.append(fd); parent = fd
        }
        return true
    }

    // https://bford.info/cachedir/: a regular non-symlink file, with this exact
    // 43-byte prefix. A newline is not required; the rest need not be loaded.
    private static let prefix = Array("Signature: 8a477f597d28d172789f06886806bc55".utf8)
    private static func validTag(_ root: Int32) -> Bool {
        let fd = openat(root, "CACHEDIR.TAG", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= Int64(prefix.count) else { return false }
        var bytes = [UInt8](repeating: 0, count: prefix.count)
        var offset = 0, interruptions = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            }
            if count < 0 {
                if errno == EINTR, interruptions < 3 { interruptions += 1; continue }
                return false
            }
            guard count > 0 else { return false }
            offset += count
        }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              fstatat(root, "CACHEDIR.TAG", &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_mode & S_IFMT == S_IFREG, named.st_dev == after.st_dev, named.st_ino == after.st_ino,
              named.st_size == after.st_size,
              named.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              named.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              named.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              named.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { return false }
        return bytes == prefix
    }
}
