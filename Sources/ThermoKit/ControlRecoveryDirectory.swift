import Darwin
import Foundation

/// Root controls share a private recovery location, independent of /var/run's
/// platform-specific group permissions. Existing unsafe directories are refused.
enum ControlRecoveryDirectory {
    static func prepare(parentPath: String = "/Library/Application Support", owner: uid_t = 0) throws {
        guard geteuid() == owner else { throw BatteryGateError("Control recovery requires its directory owner") }
        let parent = open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard parent >= 0 else { throw BatteryGateError("Control recovery parent is unavailable") }
        defer { close(parent) }
        func verifyParent() throws {
            var opened = stat(), named = stat()
            guard fstat(parent, &opened) == 0, lstat(parentPath, &named) == 0,
                  opened.st_mode & S_IFMT == S_IFDIR, named.st_mode & S_IFMT == S_IFDIR,
                  opened.st_uid == owner, named.st_uid == owner,
                  opened.st_mode & 0o022 == 0, named.st_mode & 0o022 == 0,
                  opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
                throw BatteryGateError("Control recovery parent identity or permissions are unsafe")
            }
        }
        try verifyParent()
        guard mkdirat(parent, "dev.thermo", 0o700) == 0 || errno == EEXIST else { throw BatteryGateError("Cannot create control recovery directory") }
        let child = openat(parent, "dev.thermo", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard child >= 0 else { throw BatteryGateError("Control recovery directory is unavailable") }
        defer { close(child) }
        var opened = stat(), named = stat()
        guard fstat(child, &opened) == 0, fstatat(parent, "dev.thermo", &named, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_mode & S_IFMT == S_IFDIR, named.st_mode & S_IFMT == S_IFDIR,
              opened.st_uid == owner, named.st_uid == owner,
              opened.st_mode & 0o022 == 0, named.st_mode & 0o022 == 0,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
              fsync(parent) == 0 else { throw BatteryGateError("Control recovery directory identity or permissions are unsafe") }
        try verifyParent()
    }
}
