import AgentCore
import Darwin
import Foundation

/// The bundle and its declared key files, including the exact Info.plist bytes used for parsing.
/// This does not seal all recursive contents or replace code-signature validation.
public struct AppReviewIdentity: Codable, Sendable, Equatable {
    var files: [String: String]

    static func capture(_ path: String) -> AppReviewIdentity? {
        capture(path, metadata: AppMetadata.read(path + "/Contents/Info.plist"))
    }
    static func capture(_ path: String, metadata: AppMetadata.Snapshot?) -> AppReviewIdentity? {
        let plistPath = path + "/Contents/Info.plist"
        if metadata == nil {
            var missing = stat()
            guard lstat(plistPath, &missing) != 0, errno == ENOENT else { return nil }
        }
        var paths = ["", "/Contents/Info.plist", "/Contents/_CodeSignature/CodeResources"]
        if let value = metadata?.info["CFBundleExecutable"] {
            guard let executable = value as? String, !executable.isEmpty,
                  executable != ".", executable != "..", !executable.contains("/") else { return nil }
            paths.append("/Contents/MacOS/" + executable)
        }
        var files: [String: String] = [:]
        for suffix in paths {
            var st = stat()
            if lstat(path + suffix, &st) != 0 {
                guard !suffix.isEmpty, errno == ENOENT else { return nil }
                files[suffix] = "missing"; continue
            }
            let expected = suffix.isEmpty ? S_IFDIR : S_IFREG
            guard st.st_mode & S_IFMT == expected else { return nil }
            files[suffix] = AppDataReviewIdentity.text(st)
        }
        if let metadata {
            guard files["/Contents/Info.plist"] == metadata.identity,
                  AppDataReviewIdentity.of(plistPath) == metadata.identity else { return nil }
            files["/Contents/Info.plist#sha256"] = metadata.digest
        }
        guard AppDataReviewIdentity.of(path) == files[""] else { return nil }
        return AppReviewIdentity(files: files)
    }
}
