import AVFoundation
import Foundation

/// Previews play in AVPlayer instead of YunX's embedded ffplay. AVPlayer handles MP4 and HLS only.
public enum MediaPreview {
    public enum Kind: Sendable, Equatable { case mp4, hls }

    public static func kind(of url: URL) -> Kind? {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v", "mov": return .mp4
        case "m3u8": return .hls
        default: return nil
        }
    }

    /// Signed CDN links often have no extension, so the file's own name decides then.
    public static func kind(of url: URL, fileName: String) -> Kind? {
        kind(of: url) ?? kind(of: URL(fileURLWithPath: fileName))
    }

    /// `headers` usually carry a cookie or referer, so they never go on the asset: see `MediaPreviewRelay`.
    public static func makePlayer(url: URL, headers: [String: String] = [:], fileName: String = "") -> AVPlayer? {
        guard let kind = kind(of: url, fileName: fileName) else { return nil }
        let asset = headers.isEmpty ? AVURLAsset(url: url) : MediaPreviewRelay.makeAsset(url: url, headers: headers, kind: kind)
        return asset.map { AVPlayer(playerItem: AVPlayerItem(asset: $0)) }
    }
}
