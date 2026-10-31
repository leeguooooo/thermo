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

    /// `headers` usually carry a cookie or referer: they stay on this asset and are never stored.
    public static func makePlayer(url: URL, headers: [String: String] = [:]) -> AVPlayer? {
        guard kind(of: url) != nil else { return nil }
        let options: [String: Any] = headers.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        return AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url, options: options)))
    }
}
