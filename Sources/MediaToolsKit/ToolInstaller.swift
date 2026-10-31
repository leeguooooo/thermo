import CryptoKit
import Foundation

public struct ToolDownloadProgress: Sendable, Equatable {
    public var downloaded: Int64
    public var total: Int64
}

/// Shared download, checksum and install steps for the Gopeed and FFmpeg archives.
enum ToolInstaller {
    private static let chunkReportInterval: TimeInterval = 0.3

    /// Streams `url` into `destination` from byte zero and returns its SHA-256 hex digest.
    static func download(
        transport: MediaHTTPTransport, url: URL, headers: [String: String] = [:], to destination: URL, declaredSize: Int64,
        onProgress: @Sendable (ToolDownloadProgress) -> Void
    ) async throws -> (digest: String, finalURL: URL) {
        guard url.scheme?.lowercased() == "https" else { throw MediaToolsError.insecureURL }
        let response = try await transport.send(MediaRequest(url: url, headers: headers))
        guard response.isSuccess else { throw MediaToolsError.httpStatus(response.statusCode) }
        guard response.finalURL.scheme?.lowercased() == "https" else { throw MediaToolsError.insecureURL }

        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var hasher = SHA256()
        var written: Int64 = 0
        var lastReport = Date.distantPast
        for try await chunk in response.body {
            try Task.checkCancellation()
            try handle.write(contentsOf: chunk)
            hasher.update(data: chunk)
            written += Int64(chunk.count)
            if Date().timeIntervalSince(lastReport) >= chunkReportInterval {
                lastReport = Date()
                onProgress(ToolDownloadProgress(downloaded: written, total: declaredSize))
            }
        }
        if declaredSize > 0, written != declaredSize {
            throw MediaToolsError.incompleteDownload(expected: declaredSize, actual: written)
        }
        onProgress(ToolDownloadProgress(downloaded: written, total: declaredSize > 0 ? declaredSize : written))
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), response.finalURL)
    }

    /// `sha256:<hex>` or bare hex. Nil when no SHA-256 was published.
    static func expectedSHA256(_ digest: String) -> String? {
        let hex = (digest.split(separator: ":", maxSplits: 1).last.map(String.init) ?? digest)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    /// Extracts with ditto into an empty directory so entry names never choose a path of ours,
    /// then installs the one regular file called `name`.
    static func install(
        archive: URL, entryName name: String, to target: URL, root: MediaToolsRoot, runner: ToolRunner
    ) async throws {
        let workspace = try root.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", archive.path, workspace.path],
            timeout: 300, onStdoutLine: { _ in })
        guard result.exitCode == 0, !result.timedOut else { throw MediaToolsError.extractionFailed }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let walker = FileManager.default.enumerator(at: workspace, includingPropertiesForKeys: keys)
        var found: URL?
        while let item = walker?.nextObject() as? URL {
            guard item.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame,
                  let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            found = item
            break
        }
        guard let found else { throw MediaToolsError.missingInArchive(name) }
        try installBinary(from: found, to: target)
    }

    /// Atomic, so a failed install leaves any working tool in place.
    static func installBinary(from source: URL, to target: URL) throws {
        guard MediaToolsRoot.isMachO(source) else { throw MediaToolsError.executableRejected("not Mach-O") }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: source, to: staging)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        removexattr(staging.path, "com.apple.quarantine", 0)
        guard rename(staging.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
