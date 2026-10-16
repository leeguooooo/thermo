import Darwin
import Foundation

/// Cooperating writers lock a separate stable file; the replaceable whitelist cannot be the lock.
/// Directory-relative writes keep temporary-file cleanup bound to the directory we opened.
struct WhitelistWriteTransaction {
    static let lockName = ".whitelist.lock"
    let home: String
    let directory: URL
    let directoryDescriptor: Int32
    let lockDescriptor: Int32

    static func run<T>(home: String, _ body: (Self) throws -> T) throws -> T {
        let location = try Whitelist.checkedLocation(home: home), directory = location.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard parent >= 0 else { throw Whitelist.error(tr("whitelist folder could not be locked")) }
        defer { close(parent) }
        var folder = stat()
        guard fstat(parent, &folder) == 0, folder.st_mode & S_IFMT == S_IFDIR, folder.st_uid == getuid(), folder.st_mode & 0o022 == 0 else {
            throw Whitelist.error(tr("whitelist folder is not trusted for writing"))
        }
        let lock = openat(parent, lockName, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw Whitelist.error(tr("whitelist write lock is unavailable")) }
        defer { close(lock) }
        let context = Self(home: home, directory: directory, directoryDescriptor: parent, lockDescriptor: lock)
        guard context.matches() else { throw Whitelist.error(tr("whitelist write lock is unavailable")) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Whitelist.error(tr("whitelist is being edited by another process; try again")) }
        defer { flock(lock, LOCK_UN) }
        guard context.matches() else { throw Whitelist.error(tr("whitelist folder changed during editing; try again")) }
        return try body(context)
    }

    func matches() -> Bool {
        guard (try? Whitelist.checkedLocation(home: home)) != nil else { return false }
        var opened = stat(), visible = stat(), lock = stat(), namedLock = stat()
        return fstat(directoryDescriptor, &opened) == 0 && lstat(directory.path, &visible) == 0 &&
            opened.st_dev == visible.st_dev && opened.st_ino == visible.st_ino &&
            opened.st_mode & S_IFMT == S_IFDIR && visible.st_mode & S_IFMT == S_IFDIR &&
            opened.st_uid == getuid() && opened.st_mode & 0o022 == 0 &&
            fstat(lockDescriptor, &lock) == 0 && fstatat(directoryDescriptor, Self.lockName, &namedLock, AT_SYMLINK_NOFOLLOW) == 0 &&
            lock.st_mode & S_IFMT == S_IFREG && lock.st_uid == getuid() && lock.st_mode & 0o022 == 0 && lock.st_nlink == 1 && lock.st_size == 0 &&
            namedLock.st_nlink == 1 && AppDataReviewIdentity.text(lock) == AppDataReviewIdentity.text(namedLock)
    }

    func identity() throws -> String? {
        var info = stat()
        if fstatat(directoryDescriptor, "whitelist", &info, AT_SYMLINK_NOFOLLOW) == 0 { return AppDataReviewIdentity.text(info) }
        if errno == ENOENT { return nil }
        throw Whitelist.error(tr("whitelist could not be inspected: %1$@", Whitelist.url(home: home).path))
    }

    func snapshot() throws -> (text: String?, identity: String?) {
        let expected = try identity(), text = try Whitelist.read(home: home)
        guard matches(), try identity() == expected else { throw Whitelist.error(tr("whitelist changed during editing; review it and try again")) }
        return (text, expected)
    }

    func write(_ lines: [String], expected: String?, beforeCommit: () throws -> Void) throws {
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        guard data.count <= Whitelist.maxBytes else { throw Whitelist.error(tr("whitelist would be larger than %1$@ KB", String(Whitelist.maxBytes / 1024))) }
        let name = ".whitelist." + UUID().uuidString
        let fd = openat(directoryDescriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Whitelist.error(tr("whitelist could not be written")) }
        defer { close(fd) }
        defer {
            var owned = stat(), visible = stat()
            if fstat(fd, &owned) == 0, fstatat(directoryDescriptor, name, &visible, AT_SYMLINK_NOFOLLOW) == 0,
               owned.st_dev == visible.st_dev, owned.st_ino == visible.st_ino {
                unlinkat(directoryDescriptor, name, 0)
            }
        }
        guard fchmod(fd, 0o600) == 0 else { throw Whitelist.error(tr("whitelist could not be written")) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(fd) == 0 else { throw Whitelist.error(tr("whitelist could not be written")) }
        var prepared = stat()
        guard fstat(fd, &prepared) == 0, prepared.st_size == data.count else { throw Whitelist.error(tr("whitelist could not be written")) }
        try beforeCommit()
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, fstatat(directoryDescriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              after.st_nlink == 1, named.st_nlink == 1,
              AppDataReviewIdentity.text(prepared) == AppDataReviewIdentity.text(after),
              AppDataReviewIdentity.text(after) == AppDataReviewIdentity.text(named) else {
            throw Whitelist.error(tr("whitelist temporary file changed; nothing was committed"))
        }
        guard matches(), try identity() == expected else { throw Whitelist.error(tr("whitelist changed during editing; review it and try again")) }
        let flags: UInt32 = expected == nil ? UInt32(RENAME_EXCL) : 0
        guard renameatx_np(directoryDescriptor, name, directoryDescriptor, "whitelist", flags) == 0 else { throw Whitelist.error(tr("whitelist could not be written")) }
        guard matches() else { throw Whitelist.error(tr("whitelist folder changed during editing; try again")) }
    }
}
