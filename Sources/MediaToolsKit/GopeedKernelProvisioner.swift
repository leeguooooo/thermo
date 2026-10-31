import Foundation

public struct GopeedKernelPlan: Sendable, Equatable {
    public var version: String
    public var assetName: String
    /// Mirror URL when a prefix was given, otherwise the direct URL.
    public var url: URL
    public var fallbackURL: URL?
    public var size: Int64
    /// The pinned SHA-256. Always present: there is no unverified install.
    public var digest: String
}

/// Fetches the pinned `gopeed-web-<tag>-macos-arm64.zip` and hands it to `GopeedEngine`.
public struct GopeedKernelProvisioner: Sendable {
    public enum Stage: Sendable, Equatable { case resolving, downloading, verifying, installing, done }

    private static let userAgent = "Thermo"

    private let transport: MediaHTTPTransport
    private let root: MediaToolsRoot
    private let pin: PinnedTool
    private let version: String

    public init(root: MediaToolsRoot, transport: MediaHTTPTransport = URLSessionMediaTransport.internet) {
        self.init(root: root, transport: transport, pin: PinnedTools.gopeed, version: PinnedTools.gopeedVersion)
    }

    init(root: MediaToolsRoot, transport: MediaHTTPTransport, pin: PinnedTool, version: String) {
        self.root = root
        self.transport = transport
        self.pin = pin
        self.version = version
    }

    /// No network: the release is fixed in source, so GitHub's "latest" cannot change what is installed.
    /// A mirror is safe because the pinned digest catches whatever it serves.
    public func resolvePlan(mirrorPrefix: String? = nil) -> GopeedKernelPlan {
        var primary = pin.url
        if let prefix = mirrorPrefix?.trimmingCharacters(in: .whitespaces), prefix.lowercased().hasPrefix("https://"),
           let mirrored = URL(string: prefix + pin.url.absoluteString) {
            primary = mirrored
        }
        return GopeedKernelPlan(
            version: version, assetName: pin.url.lastPathComponent, url: primary,
            fallbackURL: primary == pin.url ? nil : pin.url, size: pin.size, digest: pin.sha256)
    }

    /// Resolve, download with mirror fallback, verify, install.
    public func provision(
        engine: GopeedEngine, mirrorPrefix: String? = nil,
        onStage: @escaping @Sendable (Stage) -> Void = { _ in },
        onProgress: @escaping @Sendable (ToolDownloadProgress) -> Void = { _ in }
    ) async throws -> GopeedKernelPlan {
        onStage(.resolving)
        let plan = resolvePlan(mirrorPrefix: mirrorPrefix)
        let workspace = try root.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let archive = workspace.appendingPathComponent("gopeed.zip")

        onStage(.downloading)
        let digest = try await download(plan: plan, to: archive, onProgress: onProgress)
        onStage(.verifying)
        guard digest == ToolInstaller.expectedSHA256(plan.digest) else { throw MediaToolsError.checksumMismatch }
        onStage(.installing)
        try await engine.installFromArchive(archive, expectedSHA256: plan.digest, version: plan.version)
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
