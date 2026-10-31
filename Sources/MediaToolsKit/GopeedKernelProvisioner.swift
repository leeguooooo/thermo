import Foundation

public struct GopeedKernelPlan: Sendable, Equatable {
    public var version: String
    public var assetName: String
    /// Mirror URL when a prefix was given, otherwise the direct URL.
    public var url: URL
    public var fallbackURL: URL?
    public var size: Int64
    /// `sha256:<hex>` from the GitHub asset; empty when none was published.
    public var digest: String
}

/// Fetches the official `gopeed-web-<tag>-macos-arm64.zip` and hands it to `GopeedEngine`.
public struct GopeedKernelProvisioner: Sendable {
    public enum Stage: Sendable, Equatable { case resolving, downloading, verifying, installing, done }

    static let latestRelease = URL(string: "https://api.github.com/repos/GopeedLab/gopeed/releases/latest")!
    private static let userAgent = "Thermo"

    private let transport: MediaHTTPTransport
    private let root: MediaToolsRoot

    public init(root: MediaToolsRoot, transport: MediaHTTPTransport = URLSessionMediaTransport.internet) {
        self.root = root
        self.transport = transport
    }

    public func resolvePlan(mirrorPrefix: String? = nil) async throws -> GopeedKernelPlan {
        let response = try await transport.send(MediaRequest(
            url: Self.latestRelease, headers: ["Accept": "application/vnd.github+json", "User-Agent": Self.userAgent]))
        guard response.isSuccess else { throw MediaToolsError.httpStatus(response.statusCode) }
        let data = try await response.collect(limit: 8 << 20)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaToolsError.releaseMalformed("not JSON")
        }
        guard let tag = json["tag_name"] as? String, !tag.isEmpty else { throw MediaToolsError.releaseMalformed("no tag") }
        let wanted = "gopeed-web-\(tag)-macos-arm64.zip"
        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String)?.caseInsensitiveCompare(wanted) == .orderedSame }) else {
            throw MediaToolsError.assetNotFound(wanted)
        }
        guard let direct = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
              direct.scheme?.lowercased() == "https" else { throw MediaToolsError.insecureURL }
        let digest = asset["digest"] as? String ?? ""
        var primary = direct
        // A mirror is only trusted when the GitHub digest can catch what it serves.
        if let prefix = mirrorPrefix?.trimmingCharacters(in: .whitespaces), !prefix.isEmpty,
           ToolInstaller.expectedSHA256(digest) != nil, prefix.lowercased().hasPrefix("https://"),
           let mirrored = URL(string: prefix + direct.absoluteString) {
            primary = mirrored
        }
        return GopeedKernelPlan(
            version: tag, assetName: wanted, url: primary, fallbackURL: primary == direct ? nil : direct,
            size: (asset["size"] as? NSNumber)?.int64Value ?? 0, digest: digest)
    }

    /// Resolve, download with mirror fallback, verify, install.
    public func provision(
        engine: GopeedEngine, mirrorPrefix: String? = nil,
        onStage: @escaping @Sendable (Stage) -> Void = { _ in },
        onProgress: @escaping @Sendable (ToolDownloadProgress) -> Void = { _ in }
    ) async throws -> GopeedKernelPlan {
        onStage(.resolving)
        let plan = try await resolvePlan(mirrorPrefix: mirrorPrefix)
        let workspace = try root.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = workspace.appendingPathComponent("gopeed.zip")

        onStage(.downloading)
        let digest = try await download(plan: plan, to: archive, onProgress: onProgress)
        if let expected = ToolInstaller.expectedSHA256(plan.digest) {
            onStage(.verifying)
            guard digest == expected else { throw MediaToolsError.checksumMismatch }
        }
        onStage(.installing)
        try await engine.installFromArchive(archive)
        onStage(.done)
        return plan
    }

    private func download(
        plan: GopeedKernelPlan, to archive: URL, onProgress: @escaping @Sendable (ToolDownloadProgress) -> Void
    ) async throws -> String {
        var lastError: Error = MediaToolsError.incompleteDownload(expected: plan.size, actual: 0)
        for candidate in [plan.url, plan.fallbackURL].compactMap({ $0 }) {
            do {
                return try await ToolInstaller.download(
                    transport: transport, url: candidate, headers: ["User-Agent": Self.userAgent], to: archive,
                    declaredSize: plan.size, onProgress: onProgress
                ).digest
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: archive)
            }
        }
        throw lastError
    }
}
