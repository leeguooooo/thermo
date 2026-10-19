import Foundation
import Darwin

/// Claims recorded by the containing App's packager, not attestation of a running binary.
public struct AppBuildMetadata: Codable, Equatable, Sendable {
    public enum WorkingTree: String, Codable, Sendable { case clean, dirty, unknown }
    public let version: String?
    public let build: String?
    public let sourceCommit: String?
    public let workingTree: WorkingTree

    public init(info: [String: Any]) {
        func label(_ key: String) -> String? {
            guard let s = info[key] as? String, !s.isEmpty, s.utf8.count <= 128,
                  s.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
                  s.first != ".", s.last != ".", !s.contains("..") else { return nil }
            return s
        }
        version = label("CFBundleShortVersionString")
        build = label("CFBundleVersion")
        let sha = info["ThermoBuildSourceCommit"] as? String ?? ""
        sourceCommit = [40,64].contains(sha.utf8.count) && sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) ? sha : nil
        workingTree = sourceCommit == nil ? .unknown : WorkingTree(rawValue: info["ThermoBuildWorkingTree"] as? String ?? "") ?? .unknown
    }

    /// Resolve the actual executable, never the caller's current directory or an installed neighbor.
    public static func containingCLI(executable: URL?) -> AppBuildMetadata? {
        guard let executable, executable.isFileURL else { return nil }
        let helpers = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent(), app = contents.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents", app.pathExtension == "app" else { return nil }
        let fd = open(contents.appendingPathComponent("Info.plist").path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var st = stat()
        guard fstat(fd,&st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= 1_048_576,
              let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576,
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = value as? [String: Any] else { return nil }
        return AppBuildMetadata(info: info)
    }
}
