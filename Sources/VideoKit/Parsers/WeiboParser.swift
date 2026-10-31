import Foundation

/// Weibo posts and videos.
///
/// `status` takes a wid to the mobile JSON API, `fid` goes to the video component API, and `tv`
/// carries a numeric mid that converts to a wid first.
public struct WeiboParser: VideoParser {
    public let platform = VideoPlatform.weibo
    private let http: VideoHttp

    public init(http: VideoHttp = VideoHttp()) {
        self.http = http
    }

    public func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        switch link.kind {
        case "status": return try await parseStatus(link, weiboId: link.id, cookie: cookie)
        case "tv": return try await parseStatus(link, weiboId: Self.mid2id(link.id), cookie: cookie)
        case "fid": return try await parseFid(link, cookie: cookie)
        default: throw VideoParseException(.unsupported, "不支持的微博链接形态：\(link.kind)")
        }
    }

    private func parseStatus(_ link: DetectedVideoLink, weiboId: String, cookie: String) async throws -> VideoParseResult {
        var headers = [
            "accept": "application/json, text/plain, */*",
            "referer": "https://m.weibo.cn/detail/\(weiboId)",
            "origin": "https://m.weibo.cn",
            "x-requested-with": "XMLHttpRequest",
            "mweibo-pwa": "1",
            "sec-fetch-site": "same-origin",
            "sec-fetch-mode": "cors",
            "sec-fetch-dest": "empty",
            "User-Agent": VideoHttp.uaChrome,
        ]
        if !cookie.isBlank { headers["Cookie"] = cookie }
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        // Redirects must not be followed: they lead to a login page and would carry the Cookie along.
        let response = try await http.request(
            "https://m.weibo.cn/statuses/show?id=\(weiboId)&_=\(now)", headers: headers, followRedirects: false
        )
        guard response.status == 200 else {
            switch response.status {
            case 403, 418, 429:
                throw VideoParseException(.blocked, "微博被风控拦截（HTTP \(response.status)），可更换 UA/Referer 或稍后重试")
            case 404, 410:
                throw VideoParseException(.notFound, "微博内容不存在或已删除（HTTP \(response.status)）")
            default:
                throw VideoParseException(.unknown, "微博数据获取失败（HTTP \(response.status)）")
            }
        }
        // A 200 that is not JSON is a verification or gateway page.
        let contentType = response.header("content-type") ?? ""
        guard contentType.contains("application/json") else {
            throw VideoParseException(.blocked, "微博接口返回的不是 JSON（content-type: \(contentType)），多半被风控拦截")
        }
        guard let json = VideoJSON.parseObject(response.body) else {
            throw VideoParseException(.unknown, "微博返回数据解析失败")
        }
        guard let data = json.optObject("data") else {
            throw VideoParseException(.notFound, "微博内容不存在或已删除")
        }
        return build(link, data, cookie: cookie, allowRetweet: true)
    }

    private func parseFid(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var headers = ["Referer": "https://h5.video.weibo.com/show/\(link.id)", "User-Agent": VideoHttp.uaChrome]
        if !cookie.isBlank { headers["Cookie"] = cookie }
        let text = try await http.postForm(
            "https://h5.video.weibo.com/api/component?page=/show/\(link.id)",
            form: [(key: "data", value: #"{"Component_Play_Playinfo":{"oid":"\#(link.id)"}}"#)],
            headers: headers,
            what: "微博视频"
        )
        guard let json = VideoJSON.parseObject(text) else {
            throw VideoParseException(.unknown, "微博视频接口返回数据解析失败")
        }
        guard let data = json.optObject("data")?.optObject("Component_Play_Playinfo") else {
            throw VideoParseException(.notFound, "微博视频数据为空（作品可能已删除）")
        }

        let title = data.str("title")
        // `urls` maps bitrate to link, highest first; stream_url is the lowest-bitrate fallback.
        let urls = data.optObject("urls")
        let videoUrl: String
        if let urls, let first = urls.keys.first {
            videoUrl = Self.httpsUrl(urls.str(first))
        } else {
            videoUrl = Self.httpsUrl(data.str("stream_url"))
        }
        var medias: [VideoMedia] = []
        if !videoUrl.isBlank {
            medias.append(VideoMedia(
                url: videoUrl,
                kind: .video,
                fileName: "\(fileBase(title, link)).mp4",
                headers: Self.mediaHeaders(cookie)
            ))
        }
        let user = data.optObject("reward")?.optObject("user")
        return VideoParseResult(
            platform: platform,
            title: title,
            author: user?.str("name") ?? "",
            avatar: user?.str("profile_image_url") ?? "",
            cover: Self.httpsUrl(data.str("cover_image")),
            text: Self.stripTags(data.str("text")).replacingOccurrences(of: "\n\n", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            timestampSeconds: Self.parseRealDate(data.str("real_date")),
            url: link.url,
            medias: medias
        )
    }

    /// The result has no nested repost, so a post with no media of its own becomes the post it
    /// reposts, one level only.
    private func build(_ link: DetectedVideoLink, _ data: VideoJSONObject, cookie: String, allowRetweet: Bool) -> VideoParseResult {
        let headers = Self.mediaHeaders(cookie)
        let pageInfo = data.optObject("page_info")
        let title = pageInfo?.str("title") ?? ""
        let base = fileBase(title, link)

        var medias: [VideoMedia] = []
        let videoUrl = Self.videoUrl(pageInfo)
        if !videoUrl.isBlank {
            medias.append(VideoMedia(url: videoUrl, kind: .video, fileName: "\(base).mp4", headers: headers))
        }
        if let pics = data.optArray("pics") {
            var imageIndex = 0
            for index in 0..<pics.count {
                guard let pic = pics.optObject(index), let url = pic.optObject("large")?.str("url"),
                      !url.isBlank else { continue }
                // Live Photo: videoSrc is a relay link. It must be used as is; the raw host gives 403.
                let motion = pic.str("videoSrc")
                imageIndex += 1
                medias.append(VideoMedia(
                    url: url,
                    kind: .image,
                    fileName: "\(base)_\(imageIndex).jpg",
                    headers: headers,
                    quality: motion.isBlank ? "原图" : "动图",
                    motionUrl: motion
                ))
            }
        }
        if medias.isEmpty, allowRetweet, let retweeted = data.optObject("retweeted_status") {
            return build(link, retweeted, cookie: cookie, allowRetweet: false)
        }

        let user = data.optObject("user")
        let userId = user?.optLong("id") ?? 0
        let bid = data.str("bid")
        return VideoParseResult(
            platform: platform,
            title: title,
            author: user?.str("screen_name") ?? "",
            avatar: user?.str("profile_image_url") ?? "",
            cover: pageInfo?.optObject("page_pic")?.str("url") ?? "",
            text: Self.stripTags(data.str("text").replacingOccurrences(of: "<br />", with: "\n")),
            timestampSeconds: Self.parseWeiboTime(data.str("created_at")),
            url: userId > 0 && !bid.isBlank ? "https://weibo.com/\(userId)/\(bid)" : link.url,
            medias: medias
        )
    }

    private static func videoUrl(_ pageInfo: VideoJSONObject?) -> String {
        guard let urls = pageInfo?.optObject("urls") else { return "" }
        return httpsUrl(urls.str("mp4_720p_mp4").ifBlank(urls.str("mp4_hd_mp4")).ifBlank(urls.str("mp4_ld_mp4")))
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
    }

    private static func date(_ text: String, format: String) -> Int64? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.date(from: text).map { Int64($0.timeIntervalSince1970) }
    }

    /// `Thu Oct 02 14:39:33 +0800 2025`.
    static func parseWeiboTime(_ text: String) -> Int64 {
        text.isBlank ? 0 : date(text, format: "EEE MMM dd HH:mm:ss Z yyyy") ?? 0
    }

    /// Milliseconds, seconds or a local date string.
    static func parseRealDate(_ value: String) -> Int64 {
        if value.isBlank { return 0 }
        if value.allSatisfy(\.isNumber) {
            guard let number = Int64(value) else { return 0 }
            return number > 1_000_000_000_000 ? number / 1000 : number
        }
        // SimpleDateFormat accepted a prefix, so a date with trailing text still parses.
        return date(value, format: "yyyy-MM-dd HH:mm:ss") ?? date(String(value.prefix(10)), format: "yyyy-MM-dd") ?? 0
    }

    private static func httpsUrl(_ value: String) -> String {
        if value.isBlank { return "" }
        return value.hasPrefix("http") ? value : "https:\(value)"
    }

    private static func base62(_ number: Int64) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        if number == 0 { return "0" }
        var value = number
        var out: [Character] = []
        while value > 0 {
            out.insert(alphabet[Int(value % 62)], at: 0)
            value /= 62
        }
        return String(out)
    }

    /// Splits from the end into 7-digit groups, base62-encodes each, and pads all but the leading
    /// group to 4 characters.
    static func mid2id(_ mid: String) -> String {
        let reversed = Array(mid.reversed())
        if reversed.isEmpty { return "" }
        let size = (reversed.count + 6) / 7
        var chunks: [String] = []
        for index in 0..<size {
            let piece = String(reversed[(index * 7)..<min((index + 1) * 7, reversed.count)].reversed())
            var encoded = base62(Int64(piece) ?? 0)
            if index < size - 1, encoded.count < 4 {
                encoded = String(repeating: "0", count: 4 - encoded.count) + encoded
            }
            chunks.append(encoded)
        }
        return chunks.reversed().joined()
    }

    private static func mediaHeaders(_ cookie: String) -> [String: String] {
        var headers = ["User-Agent": VideoHttp.uaChrome, "Referer": "https://weibo.com/"]
        if !cookie.isBlank { headers["Cookie"] = cookie }
        return headers
    }

    private func fileBase(_ title: String, _ link: DetectedVideoLink) -> String {
        VideoFileName.base(title, fallback: "\(platform.displayName)_\(link.id)")
    }
}
