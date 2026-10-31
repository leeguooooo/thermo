import Foundation

/// AcFun: `ajaxpipe=1` pages inline `window.videoInfo`, whose `ksPlayJson` lists m3u8 links.
/// Produces `isHls` media; merging segments belongs to the HLS download path.
public struct AcFunParser: VideoParser {
    public let platform = VideoPlatform.acfun
    private static let referer = "https://www.acfun.cn/"
    private let http: VideoHttp
    private let timeZone: TimeZone

    public init(http: VideoHttp = VideoHttp(), timeZone: TimeZone = .current) {
        self.http = http
        self.timeZone = timeZone
    }

    public func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let url = "https://www.acfun.cn/v/ac\(link.id)?quickViewId=videoInfo_new&ajaxpipe=1"
        let html = try await http.getText(url, headers: Self.headers(cookie), what: "AcFun 视频")

        guard let raw = VideoHttp.extractInlineJson(html, key: "window.videoInfo") else {
            throw VideoParseException(.notFound, "AcFun 视频信息解析失败（页面里没有 videoInfo，可能已删除）")
        }
        // Escaped twice: `\\"` to `\"`, then `\"` to `"`.
        let jsonText = VideoHttp.unescapeQuotes(raw.replacingOccurrences(of: "\\\\\"", with: "\\\""))
        guard let info = VideoJSON.parseObject(jsonText) else {
            throw VideoParseException(.unknown, "AcFun 视频信息解析失败")
        }

        let title = info.optString("title")
        guard let m3u8 = Self.pickM3u8(info) else {
            throw VideoParseException(.unknown, "AcFun 未取到视频流地址")
        }
        let base = VideoFileName.base(title, fallback: "\(platform.displayName)_\(link.id)")

        return VideoParseResult(
            platform: platform,
            title: title,
            author: info.optObject("user")?.optString("name") ?? "",
            cover: info.optString("coverUrl"),
            text: info.optString("description"),
            timestampSeconds: parseCreateTime(info.optString("createTime")),
            url: link.url,
            medias: [VideoMedia(
                url: m3u8,
                kind: .video,
                fileName: "\(base).mp4",
                isHls: true,
                headers: Self.headers(cookie),
                quality: "720P"
            )]
        )
    }

    /// The list runs 4K down to 360P; the fourth entry is about 720P. Shorter lists take the first.
    private static func pickM3u8(_ info: VideoJSONObject) -> String? {
        guard let current = info.optObject("currentVideoInfo"),
              let ksPlay = current.optObject("ksPlayJson") ?? VideoJSON.parseObject(current.optString("ksPlayJson")),
              let representations = ksPlay.optArray("adaptationSet")?.optObject(0)?.optArray("representation")
        else { return nil }
        let urls = (0..<representations.count).compactMap { index -> String? in
            guard let url = representations.optObject(index)?.optString("url"), !url.isBlank else { return nil }
            return url
        }
        return urls.count > 3 ? urls[3] : urls.first
    }

    /// Usually `2024-12-1`; numeric seconds or milliseconds are tolerated.
    private func parseCreateTime(_ value: String) -> Int64 {
        if value.isBlank { return 0 }
        if value.allSatisfy(\.isNumber) {
            guard let number = Int64(value) else { return 0 }
            return number > 1_000_000_000_000 ? number / 1000 : number
        }
        let fields = value.split(separator: " ")[0].split(separator: "-").map { Int($0) }
        guard fields.count == 3, let year = fields[0], let month = fields[1], let day = fields[2] else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return 0 }
        return Int64(date.timeIntervalSince1970)
    }

    private static func headers(_ cookie: String) -> [String: String] {
        var headers = ["User-Agent": VideoHttp.uaChrome, "Referer": referer]
        if !cookie.isBlank { headers["Cookie"] = cookie }
        return headers
    }
}
