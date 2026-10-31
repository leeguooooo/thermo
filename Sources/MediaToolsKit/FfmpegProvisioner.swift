import Foundation

public enum FfmpegTool: String, CaseIterable, Sendable {
    case ffmpeg
    case ffprobe
}

public struct FfmpegInstallReceipt: Sendable, Equatable {
    public var tool: FfmpegTool
    public var build: String
}

/// Installs the pinned FFmpeg build from martin-riedl.de. ffplay is left out: previews use AVPlayer.
public struct FfmpegProvisioner: Sendable {
    private let root: MediaToolsRoot
    private let transport: MediaHTTPTransport
    private let runner: ToolRunner
    private let pins: @Sendable (FfmpegTool) -> PinnedTool

    public init(root: MediaToolsRoot, transport: MediaHTTPTransport = URLSessionMediaTransport.internet, runner: ToolRunner = ProcessToolRunner()) {
        self.init(root: root, transport: transport, runner: runner, pins: PinnedTools.ffmpeg)
    }

    init(root: MediaToolsRoot, transport: MediaHTTPTransport, runner: ToolRunner, pins: @escaping @Sendable (FfmpegTool) -> PinnedTool) {
        self.root = root
        self.transport = transport
        self.runner = runner
        self.pins = pins
    }

    public var isInstalled: Bool {
        (try? root.validatedExecutable(root.ffmpegExecutable)) != nil
    }

    public func provision(
        tools: [FfmpegTool] = FfmpegTool.allCases,
        onProgress: @escaping @Sendable (FfmpegTool, ToolDownloadProgress) -> Void = { _, _ in }
    ) async throws -> [FfmpegInstallReceipt] {
        var receipts: [FfmpegInstallReceipt] = []
        for tool in tools {
            let pin = pins(tool)
            let workspace = try root.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: workspace) }
            let archive = workspace.appendingPathComponent("\(tool.rawValue).zip")
            _ = try await ToolInstaller.download(
                transport: transport, url: pin.url, to: archive, declaredSize: pin.size,
                onProgress: { onProgress(tool, $0) })
            let target = root.ffmpegBin.appendingPathComponent(tool.rawValue)
            try await ToolInstaller.install(
                archive: archive, expectedSHA256: pin.sha256, entryName: tool.rawValue, to: target, root: root, runner: runner)
            receipts.append(FfmpegInstallReceipt(tool: tool, build: PinnedTools.ffmpegBuild))
        }
        return receipts
    }

    /// Deletes only the private copy.
    @discardableResult
    public func uninstall() -> Bool {
        (try? FileManager.default.removeItem(at: root.ffmpegBin.deletingLastPathComponent())) != nil
    }
}
