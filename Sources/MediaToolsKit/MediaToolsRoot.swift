import Foundation

public enum MediaToolsError: Error, Equatable, Sendable {
    case responseTooLarge
    case httpStatus(Int)
    case insecureURL
    case incompleteDownload(expected: Int64, actual: Int64)
    case checksumMismatch
    case missingInArchive(String)
    case extractionFailed
    case executableOutsideRoot
    case executableRejected(String)
    case releaseMalformed(String)
    case assetNotFound(String)
}

/// Every downloaded tool lives here. It is the only place a tool may be launched from, which is why
/// this port does not search PATH or Homebrew the way YunX does.
public struct MediaToolsRoot: Sendable {
    public let url: URL

    init(url: URL) {
        self.url = url.standardizedFileURL
    }

    /// `~/Library/Application Support/Thermo/MediaTools`.
    public static func applicationSupport() throws -> MediaToolsRoot {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return MediaToolsRoot(url: support.appendingPathComponent("Thermo/MediaTools", isDirectory: true))
    }

    var gopeedDir: URL { url.appendingPathComponent("gopeed", isDirectory: true) }
    var gopeedExecutable: URL { gopeedDir.appendingPathComponent("bin/gopeed") }
    var gopeedStorage: URL { gopeedDir.appendingPathComponent("storage", isDirectory: true) }
    var gopeedPIDFile: URL { gopeedDir.appendingPathComponent("engine.pid") }
    var ffmpegBin: URL { url.appendingPathComponent("ffmpeg/bin", isDirectory: true) }
    var ffmpegExecutable: URL { ffmpegBin.appendingPathComponent("ffmpeg") }
    var ffprobeExecutable: URL { ffmpegBin.appendingPathComponent("ffprobe") }
    var temporaryDir: URL { url.appendingPathComponent("tmp", isDirectory: true) }

    func makeTemporaryDirectory() throws -> URL {
        let dir = temporaryDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// The gate in front of every launch: a regular Mach-O file of ours, inside the root, that nobody else can rewrite.
    func validatedExecutable(_ candidate: URL) throws -> URL {
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(rootPath + "/") else { throw MediaToolsError.executableOutsideRoot }
        var info = stat()
        guard lstat(candidate.path, &info) == 0 else { throw MediaToolsError.executableRejected("missing") }
        guard info.st_mode & S_IFMT == S_IFREG else { throw MediaToolsError.executableRejected("not a regular file") }
        guard info.st_uid == geteuid() else { throw MediaToolsError.executableRejected("wrong owner") }
        guard info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { throw MediaToolsError.executableRejected("writable by others") }
        guard Self.isMachO(candidate) else { throw MediaToolsError.executableRejected("not Mach-O") }
        return candidate
    }

    static func isMachO(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
        return [[0xCF, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE], [0xCA, 0xFE, 0xBA, 0xBF]].contains(Array(magic))
    }
}

enum Redaction {
    private static let query = try! NSRegularExpression(pattern: #"(https?://[^\s"'?]+)\?[^\s"']*"#, options: [.caseInsensitive])

    /// Signed download URLs carry tokens in the query; engine messages may quote them.
    static func stripURLQueries(_ text: String) -> String {
        query.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
    }
}
