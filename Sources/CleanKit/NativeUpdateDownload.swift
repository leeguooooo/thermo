import AgentCore
import Darwin
import Foundation

extension NativeUpdateTransaction {
    public typealias ArchiveDownloader = @Sendable (URL, URL, Int64?) async throws -> Void

    public static func installationRefusal(_ check: NativeUpdateCheck) -> String? {
        guard check.status == "available", let release = check.release,
              check.source.kind == "sparkle", check.source.blocked == nil else { return "Check this app's update feed before installing" }
        guard ["zip", "dmg"].contains(release.downloadURL?.pathExtension.lowercased() ?? "") else { return "This archive format must be installed by the original updater" }
        if let type = release.installationType, type != "application" { return "This archive format must be installed by the original updater" }
        guard release.signature != nil,
              let info = NSDictionary(contentsOfFile: check.source.app.path + "/Contents/Info.plist"),
              let value = info["SUPublicEDKey"] as? String, Data(base64Encoded: value)?.count == 32 else {
            return "This update requires the original updater because its Ed25519 proof is unavailable"
        }
        if check.source.app.bundleID?.hasPrefix("dev.thermo.") == true { return "Update Thermo from its own update settings" }
        return nil
    }

    /// Rechecks the feed, downloads into a private workspace, authenticates the exact archive,
    /// prepares the app, and commits through the same recoverable transaction used by local tests.
    public static func installAvailable(_ reviewed: NativeUpdateCheck, home: String = NSHomeDirectory(),
                                        feedFetcher: NativeAppUpdates.Fetcher? = nil, downloader: ArchiveDownloader? = nil) async -> NativeInstallResult {
        if let why = installationRefusal(reviewed) { return NativeInstallResult(outcome: "failed", message: why) }
        let fresh = await NativeAppUpdates.check(reviewed.source, fetcher: feedFetcher)
        do {
            guard fresh.status == "available", let expected = reviewed.release, let current = fresh.release, let url = current.downloadURL else {
                throw failure("The update changed after review; check it again")
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            // Signed URLs may rotate on every request. Pin the authenticated bytes and release
            // constraints, rather than an expiring CDN query string.
            var expectedMetadata = expected, currentMetadata = current
            expectedMetadata.downloadHost = nil; currentMetadata.downloadHost = nil
            expectedMetadata.enclosureFingerprint = ""; currentMetadata.enclosureFingerprint = ""
            expectedMetadata.signature = nil; currentMetadata.signature = nil
            guard expected.signature != nil, current.signature != nil,
                  try encoder.encode(expectedMetadata) == encoder.encode(currentMetadata) else {
                throw failure("The update changed after review; check it again")
            }
            if let why = targetRefusal(reviewed.source.app.path, home: home, processes: ProcessTable.current(.init(cpu: false))) { throw failure(why) }
            let root = try storage(home), directory = root + "/download-" + UUID().uuidString
            try privateDirectory(directory)
            let identity = FileIdentity.of(directory)
            defer { if FileIdentity.of(directory) == identity { try? FileManager.default.removeItem(atPath: directory) } }
            let archive = URL(fileURLWithPath: directory + "/payload.archive")
            if let downloader { try await downloader(url, archive, current.length) }
            else { try await download(url, to: archive, length: current.length) }
            try Task.checkCancellation()
            let prepared = try prepare(fresh, archive: archive, home: home, reviewedArchiveSignature: expected.signature)
            defer { try? discard(prepared, home: home) }
            return install(prepared, home: home)
        } catch is CancellationError { return NativeInstallResult(outcome: "failed", message: "Update preparation stopped; the installed app was not replaced") }
        catch { return NativeInstallResult(outcome: "failed", message: error.localizedDescription) }
    }

    static func download(_ url: URL, to destination: URL, length: Int64?) async throws {
        guard NativeAppUpdates.https(url), length.map({ $0 > 0 && $0 <= 2 * 1024 * 1024 * 1024 }) ?? true else {
            throw failure("The archive URL or size is unsupported")
        }
        let config = URLSessionConfiguration.ephemeral
        config.urlCredentialStorage = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: NativeAppUpdates.FeedRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Thermo-UpdateDownload", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.url.map(NativeAppUpdates.https) == true,
              response.expectedContentLength <= 2 * 1024 * 1024 * 1024 else { throw failure("The archive download did not return a supported response") }
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("Cannot create the private archive file") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var buffer = Data(), count: Int64 = 0
        buffer.reserveCapacity(65_536)
        for try await byte in bytes {
            count += 1
            guard count <= 2 * 1024 * 1024 * 1024, length.map({ count <= $0 }) ?? true else { throw failure("The archive exceeds its allowed size") }
            buffer.append(byte)
            if buffer.count == 65_536 {
                try Task.checkCancellation(); try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        try handle.synchronize()
        guard count > 0, length.map({ count == $0 }) ?? true else { throw failure("The archive download is incomplete") }
    }
}
