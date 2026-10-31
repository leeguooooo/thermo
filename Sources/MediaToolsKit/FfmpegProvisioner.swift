import Foundation

public enum FfmpegTool: String, CaseIterable, Sendable {
    case ffmpeg
    case ffprobe
}

public struct FfmpegInstallReceipt: Sendable, Equatable {
    public var tool: FfmpegTool
    /// False when the publisher served no checksum for this build.
    public var checksumVerified: Bool
}

/// Installs FFmpeg builds from martin-riedl.de. ffplay is left out: previews use AVPlayer.
public struct FfmpegProvisioner: Sendable {
    private let root: MediaToolsRoot
    private let transport: MediaHTTPTransport
    private let runner: ToolRunner

    public init(root: MediaToolsRoot, transport: MediaHTTPTransport = URLSessionMediaTransport.internet, runner: ToolRunner = ProcessToolRunner()) {
        self.root = root
        self.transport = transport
        self.runner = runner
    }

    public var isInstalled: Bool {
        (try? root.validatedExecutable(root.ffmpegExecutable)) != nil
    }

    static func releaseURL(_ tool: FfmpegTool) -> URL {
        URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/\(tool.rawValue).zip")!
    }

    public func provision(
        tools: [FfmpegTool] = FfmpegTool.allCases,
        onProgress: @escaping @Sendable (FfmpegTool, ToolDownloadProgress) -> Void = { _, _ in }
    ) async throws -> [FfmpegInstallReceipt] {
        var receipts: [FfmpegInstallReceipt] = []
        for tool in tools {
            let workspace = try root.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let archive = workspace.appendingPathComponent("\(tool.rawValue).zip")
            let (digest, finalURL) = try await ToolInstaller.download(
                transport: transport, url: Self.releaseURL(tool), to: archive, declaredSize: 0,
                onProgress: { onProgress(tool, $0) })
            let expected = try await publishedChecksum(for: finalURL)
            if let expected, expected != digest { throw MediaToolsError.checksumMismatch }
            let target = root.ffmpegBin.appendingPathComponent(tool.rawValue)
            try await ToolInstaller.install(archive: archive, entryName: tool.rawValue, to: target, root: root, runner: runner)
            receipts.append(FfmpegInstallReceipt(tool: tool, checksumVerified: expected != nil))
        }
        return receipts
    }

    /// Deletes only the private copy.
    @discardableResult
    public func uninstall() -> Bool {
        (try? FileManager.default.removeItem(at: root.ffmpegBin.deletingLastPathComponent())) != nil
    }

    /// `<resolved build url>.sha256` holds `<hex>  ffmpeg.zip`. Only a 404 means "not published":
    /// any other failure must not quietly turn into an unverified install.
    private func publishedChecksum(for finalURL: URL) async throws -> String? {
        let sidecar = URL(string: finalURL.absoluteString + ".sha256")!
        let response = try await transport.send(MediaRequest(url: sidecar))
        if response.statusCode == 404 { return nil }
        guard response.isSuccess else { throw MediaToolsError.httpStatus(response.statusCode) }
        let text = String(decoding: try await response.collect(limit: 4096), as: UTF8.self)
        guard let token = text.split(whereSeparator: \.isWhitespace).first,
              let hex = ToolInstaller.expectedSHA256(String(token)) else { throw MediaToolsError.checksumMismatch }
        return hex
    }
}
