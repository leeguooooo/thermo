import CryptoKit
import Foundation

public struct ToolDownloadProgress: Sendable, Equatable {
    public var downloaded: Int64
    public var total: Int64
}

/// Shared download, checksum and install steps for the Gopeed and FFmpeg archives.
/// Installing always takes the expected digest, so no path can place an unchecked executable.
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
            if declaredSize > 0, written + Int64(chunk.count) > declaredSize {
                throw MediaToolsError.incompleteDownload(expected: declaredSize, actual: written + Int64(chunk.count))
            }
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

    /// Throws unless `file` hashes to `expected`. A digest that cannot be parsed fails too.
    static func verify(_ file: URL, expected: String) throws {
        guard let expected = expectedSHA256(expected) else { throw MediaToolsError.checksumMismatch }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty { hasher.update(data: block) }
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
            throw MediaToolsError.checksumMismatch
        }
    }

    /// Extracts with ditto into an empty directory so entry names never choose a path of ours,
    /// then installs the one regular file called `name`.
    static func install(
        archive: URL, expectedSHA256: String, entryName name: String, to target: URL, root: MediaToolsRoot, runner: ToolRunner
    ) async throws {
        try verify(archive, expected: expectedSHA256)
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
        try place(found, at: target)
    }

    static func installBinary(from source: URL, expectedSHA256: String, to target: URL) throws {
        try verify(source, expected: expectedSHA256)
        try place(source, at: target)
    }

    /// Atomic, so a failed install leaves any working tool in place. Callers have verified the
    /// digest, which is the only thing that justifies dropping quarantine here.
    private static func place(_ source: URL, at target: URL) throws {
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
