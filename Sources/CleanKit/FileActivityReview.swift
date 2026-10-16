import Darwin
import Foundation

/// Bounded activity proof. Size aggregation is not a substitute: directories and
/// every hard-link name matter, even when their blocks were already counted.
enum FileActivityReview {
    enum Failure: Error { case recent, unknown }
    static func requireOlder(paths: [String], before cutoff: Date, maxEntries: Int = 20_000) throws {
        let unknown = Failure.unknown
        let cancellation = ScanCancellation.current
        var visited = 0
        // Unlike a size walker, activity must include roots, directories and every
        // hard-link name. Never follow links or cross a mounted volume underneath.
        for root in paths {
            var rootInfo = stat()
            guard lstat(root, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT == S_IFDIR || rootInfo.st_mode & S_IFMT == S_IFREG) else { throw unknown }
            var pending = [root]
            while let current = pending.popLast() {
                visited += 1
                guard visited <= maxEntries, cancellation?.isCancelled != true else { throw unknown }
                var info = stat()
                guard lstat(current, &info) == 0, info.st_dev == rootInfo.st_dev else { throw unknown }
                let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
                let changed = FS.countsStatusChanges ? Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1_000_000_000 : 0
                guard Date(timeIntervalSince1970: max(modified, changed)) < cutoff else {
                    throw Failure.recent
                }
                guard info.st_mode & S_IFMT == S_IFDIR else { continue }
                let fd = open(current, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw unknown }
                guard let directory = fdopendir(fd) else { close(fd); throw unknown }
                defer { closedir(directory) }
                var opened = stat(), after = stat(), named = stat()
                guard fstat(fd, &opened) == 0, AppDataReviewIdentity.text(opened) == AppDataReviewIdentity.text(info) else { throw unknown }
                while true {
                    guard cancellation?.isCancelled != true else { throw unknown }
                    errno = 0
                    guard let entry = readdir(directory) else {
                        guard errno == 0 else { throw unknown }
                        break
                    }
                    let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
                    if name == "." || name == ".." { continue }
                    guard visited + pending.count < maxEntries else { throw unknown }
                    pending.append(current + "/" + name)
                }
                guard fstat(fd, &after) == 0, lstat(current, &named) == 0,
                      AppDataReviewIdentity.text(info) == AppDataReviewIdentity.text(after),
                      AppDataReviewIdentity.text(after) == AppDataReviewIdentity.text(named) else { throw unknown }
            }
        }
        }
}
