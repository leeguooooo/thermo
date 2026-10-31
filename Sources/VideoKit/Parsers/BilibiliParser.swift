import Foundation

/// Bilibili: logged in, DASH video and audio tracks to mux on download, plus a single-file link
/// for preview. Logged out or DASH unavailable, a single low-quality `durl` file.
///
/// Only the first part of a multi-part video is parsed; bangumi and cheese are not recognised.
public struct BilibiliParser: VideoParser, QualitySelectableParser {
    public let platform = VideoPlatform.bilibili
    private static let viewURL = "https://api.bilibili.com/x/web-interface/view"
    private static let playURL = "https://api.bilibili.com/x/player/playurl"
    private static let navURL = "https://api.bilibili.com/x/web-interface/nav"
    /// DASH codec ids: 7 AVC, 12 HEVC, 13 AV1.
    private static let codecAVC = 7
    private let http: VideoHttp

    public init(http: VideoHttp = VideoHttp()) {
        self.http = http
    }

    /// The Referer is mandatory: the API and the upos CDN both refuse requests without it.
    private static func headers(_ cookie: String) -> [String: String] {
        var headers = ["User-Agent": VideoHttp.uaChrome, "Referer": "https://www.bilibili.com/"]
        if !cookie.isBlank { headers["Cookie"] = cookie }
        return headers
    }

    public func validateCookie(_ cookie: String) async throws -> String? {
        if cookie.isBlank { return nil }
        guard let json = try await jsonOrNil(Self.navURL, cookie: cookie, what: "B站登录态校验"),
              let data = json.optObject("data"), data.optBoolean("isLogin") else { return nil }
        return data.optString("uname")
    }

    public func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        try await parseWithQuality(link, cookie: cookie, qn: nil)
    }

    public func parseWithQuality(_ link: DetectedVideoLink, cookie: String, qn: Int?) async throws -> VideoParseResult {
        let viewUrl: String
        if link.id.lowercased().hasPrefix("bv") {
            viewUrl = "\(Self.viewURL)?bvid=\(link.id)"
        } else {
            let aid = link.id.hasPrefix("av") ? String(link.id.dropFirst(2)) : link.id
            viewUrl = "\(Self.viewURL)?aid=\(aid)"
        }
        let view = try await http.getJson(viewUrl, headers: Self.headers(cookie), what: "B站视频信息")
        if view.optInt("code") != 0 {
            throw VideoParseException(
                .notFound,
                "B站视频信息接口返回 code=\(view.optInt("code")) msg=\(view.optString("message"))"
            )
        }
        guard let data = view.optObject("data") else {
            throw VideoParseException(.unknown, "B站视频信息缺少 data 字段")
        }

        let bvid = data.optString("bvid")
        let cid = data.optArray("pages")?.optObject(0)?.optLong("cid") ?? data.optLong("cid")
        if bvid.isBlank || cid <= 0 {
            throw VideoParseException(.unknown, "B站视频信息缺少 bvid/cid")
        }
        let fileBase = VideoFileName.base(data.optString("title"), fallback: "bilibili_\(bvid)")

        // Anonymous DASH is usually lowest quality too, so it is not worth the longer mux path.
        if !cookie.isBlank, let dash = try await dashQuality(bvid: bvid, cid: cid, cookie: cookie, qn: qn) {
            return Self.buildResult(
                data: data,
                bvid: bvid,
                media: VideoMedia(
                    url: dash.videoUrl,
                    kind: .video,
                    fileName: "\(fileBase).mp4",
                    headers: Self.headers(cookie),
                    quality: Self.qualityLabel(dash.quality),
                    audioUrl: dash.audioUrl,
                    audioHeaders: Self.headers(cookie),
                    previewUrl: try await mergedPreviewUrl(bvid: bvid, cid: cid, cookie: cookie)
                ),
                qualities: dash.qualities,
                selectedQn: dash.quality
            )
        }

        let play = try await http.getJson(
            "\(Self.playURL)?bvid=\(bvid)&cid=\(cid)&qn=\(qn ?? 80)&fnval=1&fnver=0&fourk=1&platform=html5&high_quality=1",
            headers: Self.headers(cookie),
            what: "B站取直链"
        )
        guard let playData = play.optObject("data"), let durl = playData.optArray("durl"), durl.count > 0 else {
            throw VideoParseException(
                .unsupported,
                "B站既未返回单文件直链、也未返回可合轨的分轨流" +
                    "（code=\(play.optInt("code")) msg=\(play.optString("message"))）：该视频可能是番剧/付费内容"
            )
        }
        guard let first = durl.optObject(0) else {
            throw VideoParseException(.unknown, "B站 durl 为空")
        }
        let url = first.optString("url")
        if url.isBlank {
            throw VideoParseException(.blocked, "B站直链为空（可能需要登录或已被风控）")
        }

        return Self.buildResult(
            data: data,
            bvid: bvid,
            media: VideoMedia(
                url: Self.httpsUrl(url),
                kind: .video,
                fileName: "\(fileBase).mp4",
                size: first.optLong("size", -1),
                headers: Self.headers(cookie),
                quality: Self.qualityLabel(playData.optInt("quality"))
            ),
            qualities: Self.qualityOptions(playData),
            selectedQn: playData.optInt("quality")
        )
    }

    private static func buildResult(
        data: VideoJSONObject,
        bvid: String,
        media: VideoMedia,
        qualities: [VideoQuality],
        selectedQn: Int
    ) -> VideoParseResult {
        VideoParseResult(
            platform: .bilibili,
            title: data.optString("title"),
            author: data.optObject("owner")?.optString("name") ?? "",
            avatar: data.optObject("owner")?.optString("face") ?? "",
            cover: httpsUrl(data.optString("pic")),
            text: data.optString("desc"),
            timestampSeconds: data.optLong("pubdate"),
            url: "https://www.bilibili.com/video/\(bvid)",
            medias: [media],
            qualities: qualities,
            selectedQn: selectedQn
        )
    }

    private struct DashStream {
        let videoUrl: String
        let audioUrl: String
        let quality: Int
        let qualities: [VideoQuality]
    }

    /// Soft fetch: failures become nil so the caller can fall back. Cancellation still propagates.
    private func jsonOrNil(_ url: String, cookie: String, what: String) async throws -> VideoJSONObject? {
        do {
            return try await http.getJson(url, headers: Self.headers(cookie), what: what)
        } catch is VideoParseException {
            return nil
        }
    }

    /// Any gap returns nil: low quality that works beats an error here.
    private func dashQuality(bvid: String, cid: Int64, cookie: String, qn: Int?) async throws -> DashStream? {
        let url = "\(Self.playURL)?bvid=\(bvid)&cid=\(cid)&qn=\(qn ?? 120)&fnval=4048&fnver=0&fourk=1"
        guard let json = try await jsonOrNil(url, cookie: cookie, what: "B站取 DASH 直链"),
              let data = json.optObject("data"),
              let dash = data.optObject("dash"),
              let videos = dash.optArray("video"),
              let audios = dash.optArray("audio"),
              let bestVideo = Self.pickVideoTrack(videos, qn: qn),
              let bestAudio = Self.firstMax(Self.objects(audios)),
              let videoUrl = Self.dashPreferredUrl(bestVideo),
              let audioUrl = Self.dashPreferredUrl(bestAudio) else { return nil }
        return DashStream(
            videoUrl: videoUrl,
            audioUrl: audioUrl,
            quality: bestVideo.optInt("id"),
            qualities: Self.qualityOptions(data)
        )
    }

    private static func objects(_ array: VideoJSONArray) -> [VideoJSONObject] {
        (0..<array.count).compactMap(array.optObject)
    }

    /// Highest `id`, first in document order on ties, as Kotlin's `maxByOrNull`.
    private static func firstMax(_ items: [VideoJSONObject]) -> VideoJSONObject? {
        var best: VideoJSONObject?
        for item in items where best == nil || item.optInt("id") > best!.optInt("id") {
            best = item
        }
        return best
    }

    /// Prefers AVC for player compatibility. A chosen `qn` takes that level, else the highest
    /// level at or below it, else the highest overall.
    private static func pickVideoTrack(_ videos: VideoJSONArray, qn: Int?) -> VideoJSONObject? {
        let all = objects(videos)
        if all.isEmpty { return nil }
        let avc = all.filter { $0.optInt("codecid") == codecAVC }
        let pool = avc.isEmpty ? all : avc
        if let qn, qn > 0 {
            return pool.first { $0.optInt("id") == qn }
                ?? firstMax(pool.filter { $0.optInt("id") <= qn })
                ?? firstMax(pool)
        }
        return firstMax(pool)
    }

    /// `support_formats` first; older responses use parallel `accept_*` arrays. Highest first.
    private static func qualityOptions(_ data: VideoJSONObject) -> [VideoQuality] {
        var labels: [Int: String] = [:]
        if let formats = data.optArray("support_formats") {
            for format in objects(formats) {
                let quality = format.optInt("quality", -1)
                if quality <= 0 || labels[quality] != nil { continue }
                labels[quality] = format.optString("new_description")
                    .ifBlank(format.optString("display_desc"))
                    .ifBlank(qualityLabel(quality))
            }
        }
        if labels.isEmpty, let qualities = data.optArray("accept_quality") {
            let descriptions = data.optArray("accept_description")
            for index in 0..<qualities.count {
                let quality = qualities.optInt(index, -1)
                if quality <= 0 || labels[quality] != nil { continue }
                labels[quality] = (descriptions?.optString(index) ?? "").ifBlank(qualityLabel(quality))
            }
        }
        return labels.sorted { $0.key > $1.key }.map { VideoQuality(qn: $0.key, label: $0.value) }
    }

    /// `baseUrl` then backups, deduplicated.
    private static func dashUrls(_ stream: VideoJSONObject) -> [String] {
        var out: [String] = []
        let append = { (url: String) in if !out.contains(url) { out.append(url) } }
        let base = stream.optString("baseUrl").ifBlank(stream.optString("base_url"))
        if !base.isBlank, base != "null" { append(httpsUrl(base)) }
        for key in ["backupUrl", "backup_url"] {
            guard let backups = stream.optArray(key) else { continue }
            for index in 0..<backups.count {
                let raw = backups.optString(index)
                if !raw.isBlank, raw != "null" { append(httpsUrl(raw)) }
            }
        }
        return out
    }

    /// PCDN nodes crawl at tens of KB/s per connection, so official mirrors win.
    private static func dashPreferredUrl(_ stream: VideoJSONObject) -> String? {
        let urls = dashUrls(stream)
        return urls.first { !isPcdn($0) } ?? urls.first
    }

    private static func isPcdn(_ url: String) -> Bool {
        guard let scheme = url.range(of: "://") else { return false }
        return url[scheme.upperBound...].prefix { $0 != "/" }.lowercased().contains("mcdn")
    }

    /// Empty on failure; the preview then falls back to the main link.
    private func mergedPreviewUrl(bvid: String, cid: Int64, cookie: String) async throws -> String {
        let url = "\(Self.playURL)?bvid=\(bvid)&cid=\(cid)&qn=80&fnval=1&fnver=0&fourk=1&platform=html5&high_quality=1"
        let json = try await jsonOrNil(url, cookie: cookie, what: "B站取预览直链")
        return Self.httpsUrl(json?.optObject("data")?.optArray("durl")?.optObject(0)?.optString("url") ?? "")
    }

    private static func qualityLabel(_ qn: Int) -> String {
        switch qn {
        case 6, 7: return "240P"
        case 16: return "360P"
        case 32: return "480P"
        case 64: return "720P"
        case 74: return "720P60"
        case 80: return "1080P"
        case 112: return "1080P+"
        case 116: return "1080P60"
        case 120: return "4K"
        default: return qn > 0 ? "画质 \(qn)" : ""
        }
    }

    private static func httpsUrl(_ url: String) -> String {
        if url.isBlank { return "" }
        return url.hasPrefix("//") ? "https:\(url)" : url
    }
}
