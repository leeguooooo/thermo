import AgentCore
import Darwin
import Foundation

/// A reviewed bundle may be updated in place without replacing its outer directory.
/// Check the bundle and the files that describe its executable, without walking it.
public struct AppReviewIdentity: Codable, Sendable, Equatable {
    var files: [String: String]

    static func capture(_ path: String) -> AppReviewIdentity? {
        var paths = ["", "/Contents/Info.plist", "/Contents/_CodeSignature/CodeResources"]
        let plistPath = path + "/Contents/Info.plist"
        if let plist = NSDictionary(contentsOfFile: plistPath), let executable = plist["CFBundleExecutable"] as? String {
            guard !executable.isEmpty, executable != ".", executable != "..", !executable.contains("/") else { return nil }
            paths.append("/Contents/MacOS/" + executable)
        }
        var files: [String: String] = [:]
        for suffix in paths {
            var st = stat()
            if lstat(path + suffix, &st) != 0 {
                guard !suffix.isEmpty, errno == ENOENT else { return nil }
                files[suffix] = "missing"
                continue
            }
            // A symlinked bundle or metadata file cannot establish the reviewed target.
            guard st.st_mode & S_IFMT != S_IFLNK else { return nil }
            files[suffix] = "\(st.st_dev):\(st.st_ino):\(st.st_mode):\(st.st_size):\(st.st_mtimespec.tv_sec):\(st.st_mtimespec.tv_nsec):\(st.st_ctimespec.tv_sec):\(st.st_ctimespec.tv_nsec)"
        }
        return AppReviewIdentity(files: files)
    }
}
