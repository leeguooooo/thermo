import Foundation
import os

/// Kuaishou videos and atlases, read from the SSR `window.INIT_STATE` map of id to work.
/// No login needed; a Cookie is sent when present.
public struct KuaishouParser: VideoParser {
    public let platform = VideoPlatform.kuaishou
    private static let logger = Logger(subsystem: "com.thermo.VideoKit", category: "kuaishou")
    private let http: VideoHttp

    public init(http: VideoHttp = VideoHttp()) {
        self.http = http
    }

    public func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        // The iPhone UA is required: a desktop UA gets a SPA page with no INIT_STATE.
        var headers = ["User-Agent": VideoHttp.uaIphone, "Referer": "https://v.kuaishou.com/"]
        if !cookie.isBlank { headers["Cookie"] = cookie }

        // Share and short-video URLs are entry pages, so follow one redirect first. Long-video
        // pages have a different structure and are requested as /fw/photo/.
        let pageUrl = try await resolvePageUrl(link.url, headers: headers)
            .replacingOccurrences(of: "/fw/long-video/", with: "/fw/photo/")

        let response = try await http.request(pageUrl, headers: headers)
        try VideoHttp.requireSuccess(response, what: "快手作品页")
        guard let initJson = VideoHttp.extractInlineJson(response.body, key: "window.INIT_STATE") else {
            Self.logger.warning("""
                快手未找到 window.INIT_STATE：url=\(VideoHttp.redactedURL(pageUrl), privacy: .public) \
                status=\(response.status) bodyLen=\(response.body.utf8.count)
                """)
            throw VideoParseException(.unknown, "快手页面里没有 window.INIT_STATE（作品可能已删除或页面改版）")
        }
        let photo = try Self.findPhoto(initJson)

        let title = photo.optString("caption")
        let base = VideoFileName.base(title, fallback: Self.fallbackName(link.id))
        var medias: [VideoMedia] = []
        if let videoUrl = Self.firstUrl(photo.optArray("mainMvUrls")) {
            medias.append(VideoMedia(url: videoUrl, kind: .video, fileName: "\(base).mp4", headers: headers))
        }
        let images = Self.atlasImageUrls(photo.optObject("ext_params")?.optObject("atlas"))
        for (index, url) in images.enumerated() {
            medias.append(VideoMedia(url: url, kind: .image, fileName: "\(base)_\(index + 1).jpg", headers: headers))
        }

        return VideoParseResult(
            platform: platform,
            title: title,
            // U+3164 is a filler character common in nicknames.
            author: photo.optString("userName").replacingOccurrences(of: "\u{3164}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            avatar: photo.optString("headUrl"),
            cover: Self.firstUrl(photo.optArray("coverUrls")) ?? "",
            timestampSeconds: photo.optLong("timestamp") / 1000,
            url: link.url,
            medias: medias
        )
    }

    private func resolvePageUrl(_ url: String, headers: [String: String]) async throws -> String {
        let normalized = url.hasPrefix("http") ? url : "https://\(url)"
        guard let target = try await http.expandRedirect(normalized, headers: headers), !target.isBlank else {
            return normalized
        }
        return target
    }

    /// The first value with a photo, in document order. The key is not always the link's id.
    private static func findPhoto(_ initJson: String) throws -> VideoJSONObject {
        guard let state = VideoJSON.parseObject(initJson) else {
            throw VideoParseException(.unknown, "window.INIT_STATE 不是合法 JSON")
        }
        for key in state.keys {
            if let photo = state.optObject(key)?.optObject("photo") { return photo }
        }
        throw VideoParseException(.unknown, "window.INIT_STATE 里没有作品数据")
    }

    private static func atlasImageUrls(_ atlas: VideoJSONObject?) -> [String] {
        guard let atlas, let routes = atlas.optArray("list") else { return [] }
        let cdn = atlas.optArray("cdnList")?.optObject(0)?.optString("cdn") ?? ""
        if cdn.isBlank { return [] }
        return (0..<routes.count).map(routes.optString).filter { !$0.isBlank }.map { "https://\(cdn)/\($0)" }
    }

    private static func firstUrl(_ nodes: VideoJSONArray?) -> String? {
        guard let nodes else { return nil }
        for index in 0..<nodes.count {
            if let url = nodes.optObject(index)?.optString("url"), !url.isBlank { return url }
        }
        return nil
    }

    /// A link that came through a short URL may have no id; a timestamp keeps names apart.
    private static func fallbackName(_ id: String) -> String {
        let suffix = id.ifBlank(String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36))
        return "kuaishou_\(suffix)"
    }
}
