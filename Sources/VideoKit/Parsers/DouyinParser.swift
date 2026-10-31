import Foundation
import os

/// Douyin videos and image posts.
///
/// Plain HTTP stopped working in 2026-10: pages answer with a `byted_acrawler` JS challenge and the
/// JSON endpoints all need signatures. So a hidden browser opens the work page, and the old
/// share-page route stays only as a fallback in case Douyin reverts.
/// The ttwid is anonymous and kept in memory; a flagged one is re-registered once on the fallback.
public struct DouyinParser: VideoParser {
    public let platform = VideoPlatform.douyin

    private static let logger = Logger(subsystem: "com.thermo.VideoKit", category: "douyin")
    private static let ttwidRegisterUrl = "https://ttwid.bytedance.com/ttwid/union/register/"
    private static let iesReferer = "https://www.iesdouyin.com/"
    private static let playRatios = ["1080p", "720p", "540p", "360p"]
    /// Challenge, reload, mount, then the page's own detail request: about 25s on a cold start.
    private static let browserTimeout: TimeInterval = 40

    private let http: VideoHttp
    private let headless: any HeadlessFetching
    private let ttwid = TtwidCache()

    public init(http: VideoHttp = VideoHttp(), headless: any HeadlessFetching = SharedHeadlessWebView()) {
        self.http = http
        self.headless = headless
    }

    public func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        if let payload = await fetchViaBrowser(link) { return build(link, payload) }

        let shareUrl = "https://www.iesdouyin.com/share/\(Self.pathType(link))/\(link.id)/"
        let data = try await fetchWorkData(link, shareUrl: shareUrl, cookie: cookie)
        let mediaHeaders = Self.mediaHeaders(referer: shareUrl)

        let title = data.optStringAny("desc")
        var medias: [VideoMedia] = []
        var cover = ""
        if let images = data.optArrayAny("images"), images.count > 0 {
            for index in 0..<images.count {
                guard let url = Self.firstUrl(images.optObject(index)) else { continue }
                if cover.isBlank { cover = url }
                medias.append(VideoMedia(
                    url: url,
                    kind: .image,
                    fileName: "\(Self.base(title, link))_\(index + 1).jpg",
                    headers: mediaHeaders,
                    quality: "原图"
                ))
            }
        } else if let video = data.optObjectAny("video"),
                  let resolved = try await resolveVideo(video, headers: mediaHeaders) {
            cover = Self.firstUrl(video.optObjectAny("cover")) ?? ""
            medias.append(VideoMedia(
                url: resolved.url,
                kind: .video,
                fileName: "\(Self.base(title, link)).mp4",
                size: resolved.size,
                headers: mediaHeaders
            ))
        }

        let author = data.optObjectAny("author")
        return VideoParseResult(
            platform: platform,
            title: title,
            author: author?.optStringAny("nickname") ?? "",
            avatar: Self.firstUrl(author?.optObjectAny("avatar_thumb", "avatar_medium")) ?? "",
            cover: cover,
            timestampSeconds: data.optLongAny("create_time", "createTime"),
            url: link.url,
            medias: medias
        )
    }

    // MARK: Hidden browser

    private struct Payload {
        var title: String
        var author: String
        var images: [String]
        var video: String
        var cover: String
        var motions: [String]
    }

    private func fetchViaBrowser(_ link: DetectedVideoLink) async -> Payload? {
        let json = await headless.loadAndExtract(
            url: "https://www.douyin.com/\(Self.pathType(link))/\(link.id)",
            userAgent: VideoHttp.uaChrome,
            readyCheckJS: DouyinScripts.readyCheck,
            extractJS: DouyinScripts.extract,
            timeout: Self.browserTimeout,
            pollInterval: 0.12,
            documentStartJS: [DouyinScripts.detailHook]
        )
        guard let json, let object = VideoJSON.parseObject(json) else { return nil }
        if !object.str("error").isBlank {
            Self.logger.warning("抖音页面取数脚本失败")
            return nil
        }
        // YunX dropped blank entries here, which shifted motions onto the wrong images whenever a
        // post mixed still and motion images. Positions are kept so the pairs stay aligned.
        let images = Self.strings(object.optArray("images")).filter { !$0.isBlank }
        let motions = Self.strings(object.optArray("motions"))
        let source = object.str("src")
        let motionCount = object.str("motionCount")
        Self.logger.info("""
            抖音页面取数：src=\(source, privacy: .public) images=\(images.count) \
            motions=\(motionCount, privacy: .public)
            """)
        let video = object.str("video")
        if images.isEmpty, video.isBlank { return nil }
        return Payload(
            title: object.str("title"),
            author: object.str("author"),
            images: images,
            video: video,
            cover: object.str("cover"),
            motions: motions
        )
    }

    private func build(_ link: DetectedVideoLink, _ payload: Payload) -> VideoParseResult {
        let headers = Self.mediaHeaders(referer: "https://www.douyin.com/")
        let base = Self.base(payload.title, link)
        var medias: [VideoMedia] = []
        if payload.images.isEmpty {
            medias.append(VideoMedia(url: payload.video, kind: .video, fileName: "\(base).mp4", headers: headers))
        } else {
            for (index, url) in payload.images.enumerated() {
                let motion = index < payload.motions.count ? payload.motions[index] : ""
                let isMotion = !motion.isBlank
                medias.append(VideoMedia(
                    url: url,
                    kind: .image,
                    // A motion image is saved as a motion-photo JPEG, whatever the still's format.
                    fileName: "\(base)_\(index + 1)\(isMotion ? ".jpg" : Self.imageExtension(url))",
                    headers: headers,
                    quality: isMotion ? "动图" : "",
                    motionUrl: motion
                ))
            }
        }
        return VideoParseResult(
            platform: platform,
            title: payload.title,
            author: payload.author,
            cover: payload.cover.ifBlank(payload.images.first ?? ""),
            url: link.url,
            medias: medias
        )
    }

    private static func imageExtension(_ url: String) -> String {
        if url.contains(".webp") { return ".webp" }
        if url.contains(".png") { return ".png" }
        return ".jpg"
    }

    private static func strings(_ array: VideoJSONArray?) -> [String] {
        guard let array else { return [] }
        return (0..<array.count).map(array.optString)
    }

    // MARK: Share page fallback

    /// Douyin decides by ttwid whether to include the work, so one failed read gets a fresh ttwid.
    /// Only data problems retry; a network failure would not change.
    private func fetchWorkData(_ link: DetectedVideoLink, shareUrl: String, cookie: String) async throws -> VideoJSONObject {
        for attempt in 0...1 {
            let value = attempt == 0 ? try await ensureTtwid() : try await renewTtwid()
            // YunX sent the bare value with no `ttwid=` name, which no server reads as this cookie.
            let ttwidCookie = "ttwid=\(value)"
            do {
                let html = try await http.getText(
                    shareUrl,
                    headers: [
                        "User-Agent": VideoHttp.uaIphone,
                        "Referer": Self.iesReferer,
                        "Cookie": cookie.isBlank ? ttwidCookie : "\(ttwidCookie); \(cookie)",
                    ],
                    what: "抖音分享页"
                )
                guard let router = VideoHttp.extractInlineJson(html, key: "window._ROUTER_DATA") else {
                    throw VideoParseException(.unknown, "抖音分享页里没有 window._ROUTER_DATA（作品可能已删除或页面改版）")
                }
                return try Self.extractVideoData(router, expectedId: link.id)
            } catch let error as VideoParseException where error.kind == .unknown && attempt == 0 {
                continue
            }
        }
        throw VideoParseException(.unknown, "抖音解析失败")
    }

    private static func extractVideoData(_ routerJson: String, expectedId: String) throws -> VideoJSONObject {
        guard let router = VideoJSON.parseObject(routerJson) else {
            throw VideoParseException(.unknown, "window._ROUTER_DATA 不是合法 JSON")
        }
        guard let loaderData = router.optObject("loaderData") else {
            throw VideoParseException(.unknown, "window._ROUTER_DATA 里没有 loaderData")
        }
        guard let page = loaderData.optObject("video_(id)/page") ?? loaderData.optObject("note_(id)/page") else {
            throw VideoParseException(.unknown, "window._ROUTER_DATA 里既没有 video_(id)/page 也没有 note_(id)/page")
        }
        let info = page.optObjectAny("videoInfoRes", "video_info_res")
        let items = info?.optArrayAny("item_list", "itemList")
        if let first = items?.optObject(0) { return first }
        // A 200 page without the work: say which layer is missing and whether we were flagged.
        let detail = [
            "videoInfoRes=\(info == nil ? "缺失" : "存在")",
            "item_list=\(items.map { "长度 \($0.count)" } ?? "缺失")",
            "itemId=\(page.optStringAny("itemId", "item_id").ifBlank("缺失"))",
            "请求id=\(expectedId)",
            "isSpider=\(page.optBoolean("isSpider"))",
        ].joined(separator: ", ")
        throw VideoParseException(.unknown, "抖音没有返回该作品的数据（作品可能已删除或不可见，也可能被风控拦截）[\(detail)]")
    }

    // MARK: Direct links

    private func resolveVideo(_ video: VideoJSONObject, headers: [String: String]) async throws -> (url: String, size: Int64)? {
        let playAddr = video.optObjectAny("play_addr", "playAddr")
        if let token = Self.playToken(playAddr), let best = try await probePlay(token, headers: headers) {
            return best
        }
        // Swapping playwm for play removes the watermark.
        guard let fallback = Self.firstUrl(playAddr) else { return nil }
        return (fallback.replacingOccurrences(of: "playwm", with: "play"), -1)
    }

    private static func playToken(_ playAddr: VideoJSONObject?) -> String? {
        guard let playAddr else { return nil }
        let uri = playAddr.optStringAny("uri")
        if !uri.isBlank { return uri }
        for url in strings(playAddr.optArrayAny("url_list", "urlList")) {
            if let id = firstGroup(#"[?&]video_id=([^&\s]+)"#, url), !id.isBlank { return id }
        }
        return nil
    }

    /// The ratios are transcodes of one video, so the largest is the sharpest. One failing does not
    /// matter, and a two-byte range is enough to learn the total size.
    private func probePlay(_ videoId: String, headers: [String: String]) async throws -> (url: String, size: Int64)? {
        var best: (url: String, size: Int64)?
        var probeHeaders = headers
        probeHeaders["Range"] = "bytes=0-1"
        for ratio in Self.playRatios {
            let url = "https://aweme.snssdk.com/aweme/v1/play/?video_id=\(videoId)&ratio=\(ratio)"
            let response: VideoResponse
            do {
                response = try await http.request(url, headers: probeHeaders)
            } catch is VideoParseException {
                continue
            }
            guard (200...299).contains(response.status) else { continue }
            let size = Self.responseSize(response)
            guard size > 0 else { continue }
            if size > (best?.size ?? 0) { best = (response.finalUrl, size) }
        }
        return best
    }

    private static func responseSize(_ response: VideoResponse) -> Int64 {
        if let range = response.header("Content-Range"),
           let total = firstGroup(#"/([0-9]+)\s*$"#, range).flatMap({ Int64($0) }) {
            return total
        }
        return response.header("Content-Length").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? 0
    }

    /// CDN files: no Cookie.
    private static func mediaHeaders(referer: String) -> [String: String] {
        ["User-Agent": VideoHttp.uaIphone, "Referer": referer]
    }

    // MARK: ttwid

    private func ensureTtwid() async throws -> String {
        if let cached = await ttwid.value { return cached }
        return try await renewTtwid()
    }

    private func renewTtwid() async throws -> String {
        await ttwid.set(nil)
        let fresh = try await registerTtwid()
        await ttwid.set(fresh)
        return fresh
    }

    private func registerTtwid() async throws -> String {
        let body = #"{"region":"cn","aid":1768,"needFid":false,"service":"www.iesdouyin.com","union":true,"fid":""}"#
        let headers = ["User-Agent": VideoHttp.uaIphone, "Referer": Self.iesReferer]
        var postHeaders = headers
        postHeaders["Content-Type"] = "application/json; charset=utf-8"
        let response = try await http.request(
            Self.ttwidRegisterUrl, method: "POST", headers: postHeaders, body: Data(body.utf8)
        )
        guard (200...299).contains(response.status) else {
            throw VideoParseException(.unknown, "ttwid 注册失败（HTTP \(response.status)）")
        }
        let registered = response.header("Set-Cookie").flatMap(Self.extractTtwid)
        // The callback completes the union registration. Best effort: its failure costs nothing.
        var fromCallback: String?
        if let callback = VideoJSON.parseObject(response.body)?.optString("redirect_url"), !callback.isBlank {
            do {
                fromCallback = try await http.request(callback, headers: headers, followRedirects: false)
                    .header("Set-Cookie").flatMap(Self.extractTtwid)
            } catch is VideoParseException {
                fromCallback = nil
            }
        }
        guard let value = fromCallback ?? registered else {
            throw VideoParseException(.unknown, "ttwid 注册未返回可用 Cookie")
        }
        return value
    }

    /// URLSession folds repeated Set-Cookie headers into one, joined by commas, so a comma ends the
    /// value too. YunX read each header separately.
    private static func extractTtwid(_ setCookie: String) -> String? {
        firstGroup(#"ttwid=([^;,]+)"#, setCookie).flatMap { $0.isBlank ? nil : $0 }
    }

    // MARK: Helpers

    /// Other forms open as `video`; Douyin redirects them to the real page.
    private static func pathType(_ link: DetectedVideoLink) -> String {
        firstGroup("/(?:share/)?(video|note|slides)/", link.url) == "note" ? "note" : "video"
    }

    private static func firstUrl(_ node: VideoJSONObject?) -> String? {
        strings(node?.optArrayAny("url_list", "urlList")).first { !$0.isBlank }
    }

    private static func base(_ title: String, _ link: DetectedVideoLink) -> String {
        VideoFileName.base(title, fallback: "douyin_\(link.id)")
    }

    private static func firstGroup(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// In memory only: re-registering every parse would just invite more risk control.
private actor TtwidCache {
    private(set) var value: String?

    func set(_ newValue: String?) {
        value = newValue
    }
}

/// The same field changes case between Douyin endpoints.
private extension VideoJSONObject {
    func optStringAny(_ keys: String...) -> String {
        keys.lazy.filter { !isNull($0) }.map { optString($0) }.first { !$0.isBlank } ?? ""
    }

    func optLongAny(_ keys: String...) -> Int64 {
        keys.first { !isNull($0) }.map { optLong($0) } ?? 0
    }

    func optObjectAny(_ keys: String...) -> VideoJSONObject? {
        keys.lazy.compactMap { optObject($0) }.first
    }

    func optArrayAny(_ keys: String...) -> VideoJSONArray? {
        keys.lazy.compactMap { optArray($0) }.first
    }
}
