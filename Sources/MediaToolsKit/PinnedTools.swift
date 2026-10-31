import Foundation

public struct PinnedTool: Sendable, Equatable {
    public var url: URL
    public var size: Int64
    public var sha256: String
}

/// The exact third-party builds Thermo will execute. Moving to a new build is a source change:
/// the Gopeed digest comes from the GitHub release asset, the FFmpeg ones from the `.sha256`
/// sidecars, and all were recomputed from the downloaded archives on 2026-11-01.
public enum PinnedTools {
    public static let gopeedVersion = "v1.9.3"
    public static let ffmpegBuild = "1789931890_9.0.2"

    public static let gopeed = PinnedTool(
        url: URL(string: "https://github.com/GopeedLab/gopeed/releases/download/v1.9.3/gopeed-web-v1.9.3-macos-arm64.zip")!,
        size: 39_824_901,
        sha256: "d0a6923297c31cdcdfd9caab2e1d312b6a91a1cc3bab4d4ec43418093cc7c927")

    @Sendable public static func ffmpeg(_ tool: FfmpegTool) -> PinnedTool {
        let base = "https://ffmpeg.martin-riedl.de/download/macos/arm64/\(ffmpegBuild)/"
        switch tool {
        case .ffmpeg:
            return PinnedTool(
                url: URL(string: base + "ffmpeg.zip")!, size: 28_395_699,
                sha256: "c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924")
        case .ffprobe:
            return PinnedTool(
                url: URL(string: base + "ffprobe.zip")!, size: 28_317_701,
                sha256: "fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6")
        }
    }
}
