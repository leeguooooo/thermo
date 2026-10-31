import Foundation
import os

/// Xiaohongshu notes, read from the page's inline `window.__INITIAL_STATE__`.
///
/// A login is required: logged-out requests redirect to a login or captcha page. The share link's
/// `xsec_token` is checked per request, so its query goes on both rebuilt URLs. That query is a
/// token: it must stay out of logs and error messages.
///
/// The two page forms have different JSON:
/// `/explore/<id>` has `note.noteDetailMap[<id>].note` (`urlDefault`, `nickname`), while
/// `/discovery/item/<id>` has `noteData.data.noteData` (`url`, `nickName`).
///
/// Neither image field is downloadable as is: those carry a web processing spec and a session-
/// dependent watermark, so images are converted to the origin CDN, falling back with a notice.
public struct XhsParser: VideoParser {
    public let platform = VideoPlatform.xhs

    private static let logger = Logger(subsystem: "com.thermo.VideoKit", category: "xhs")
    private static let accept =
        "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8," +
        "application/signed-exchange;v=b3;q=0.7"
    private static let home = "https://www.xiaohongshu.com"
    private static let imageCdn = "https://sns-img-bd.xhscdn.com"
    private static let referer = "\(home)/"
    private static let loginWallMarkers = ["/login", "website-login", "captcha"]
    /// h265 has no watermark; h264 does.
    private static let streamOrder = [("h265", "H.265"), ("h264", "H.264"), ("av1", "AV1"), ("h266", "H.266")]

    private let http: VideoHttp

    public init(http: VideoHttp = VideoHttp()) {
        self.http = http
    }

    /// Probes behaviour, not cookie names: the site's JS plants a guest `web_session` too. Logged
    /// out, /explore redirects to /login. The site has no usable who-am-I API, so the name is empty.
    public func validateCookie(_ cookie: String) async throws -> String? {
        if cookie.isBlank { return nil }
        do {
            let response = try await http.request("\(Self.home)/explore", headers: Self.exploreHeaders(cookie))
            return Self.isLoginWall(response.finalUrl) ? nil : ""
        } catch is VideoParseException {
            Self.logger.warning("小红书登录态探测失败（按未登录处理）")
            return nil
        }
    }

    /// Risk control differs per path, so a failed explore tries discovery, except when a login is
    /// demanded: that is the same gate on both.
    public func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        do {
            return try await parseExplore(link, cookie: cookie)
        } catch let error as VideoParseException where error.kind != .unsupported {
            return try await parseDiscovery(link, cookie: cookie)
        }
    }

    private func parseExplore(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let url = "\(Self.home)/explore/\(link.id)\(Self.query(link))"
        let state = try Self.initialState(try await fetchPage(url, headers: Self.exploreHeaders(cookie)))
        guard let note = state.optObject("note")?.optObject("noteDetailMap")?.optObject(link.id)?.optObject("note") else {
            throw VideoParseException(.notFound, "小红书页面里没有该笔记数据")
        }
        // Having a `video` object is the test: `type` varies by path.
        if note.optObject("video") != nil, Self.pickVideo(note) == nil {
            throw VideoParseException(.unknown, "小红书视频笔记没有取到视频直链（笔记里有 video 字段，但 media.stream 里没有可用地址）")
        }
        return try await build(
            note, link, cookie: cookie, nicknameKey: "nickname",
            coverSources: Self.rawImages(note)
        )
    }

    private func parseDiscovery(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let url = "\(Self.home)/discovery/item/\(link.id)\(Self.query(link))"
        let state = try Self.initialState(try await fetchPage(url, headers: Self.discoveryHeaders(cookie)))
        guard let root = state.optObject("noteData") else {
            throw VideoParseException(.notFound, "小红书分享链接失效或内容已删除")
        }
        guard let note = root.optObject("data")?.optObject("noteData") else {
            throw VideoParseException(.notFound, "小红书页面里没有笔记数据（内容可能已删除）")
        }
        let preload = Self.imageUrls(root.optObject("normalNotePreloadData")?.optArray("imagesList")) {
            $0.str("urlSizeLarge").ifBlank($0.str("url"))
        }
        return try await build(
            note, link, cookie: cookie, nicknameKey: "nickName",
            coverSources: preload.isEmpty ? Self.rawImages(note) : preload
        )
    }

    /// Without the login check here, a login redirect would read as "deleted".
    private func fetchPage(_ url: String, headers: [String: String]) async throws -> String {
        let response = try await http.request(url, headers: headers)
        try VideoHttp.requireSuccess(response, what: "小红书笔记")
        if Self.isLoginWall(response.finalUrl) {
            throw VideoParseException(.unsupported, "小红书要求登录后才能查看笔记内容，请先到「账号」页登录小红书")
        }
        return response.body
    }

    /// The block holds bare `undefined`, which is not JSON.
    private static func initialState(_ html: String) throws -> VideoJSONObject {
        guard let raw = VideoHttp.extractInlineJson(html, key: "window.__INITIAL_STATE__") else {
            throw VideoParseException(.unknown, "小红书页面里没有笔记数据（可能被风控拦截或页面改版）")
        }
        guard let state = VideoJSON.parseObject(raw.replacingOccurrences(of: "undefined", with: "null")) else {
            throw VideoParseException(.unknown, "小红书页面数据解析失败")
        }
        return state
    }

    private func build(
        _ note: VideoJSONObject,
        _ link: DetectedVideoLink,
        cookie: String,
        nicknameKey: String,
        coverSources: [String]
    ) async throws -> VideoParseResult {
        let headers = Self.mediaHeaders(cookie)
        let title = note.str("title")
        let base = VideoFileName.base(title, fallback: "\(platform.displayName)_\(link.id)")

        var medias: [VideoMedia] = []
        var cover = ""
        var notice = ""
        if let video = Self.pickVideo(note) {
            // Display only, so not probed.
            cover = Self.watermarkFreeOrRaw(coverSources.first ?? "")
            medias.append(VideoMedia(
                url: video.url, kind: .video, fileName: "\(base).mp4", headers: headers, quality: video.quality
            ))
        } else {
            let images = try await resolveImages(Self.rawImages(note), headers: headers)
            for (index, url) in images.urls.enumerated() {
                medias.append(VideoMedia(
                    url: url, kind: .image, fileName: "\(base)_\(index + 1).jpg", headers: headers, quality: "原图"
                ))
            }
            if images.fallbacks > 0 {
                notice = "\(images.fallbacks) 张图片没有可用的去水印原图，已改用平台地址（可能带水印）"
            }
        }

        let user = note.optObject("user")
        return VideoParseResult(
            platform: platform,
            title: title,
            author: user?.str(nicknameKey) ?? "",
            avatar: user?.str("avatar") ?? "",
            cover: cover,
            text: note.str("desc"),
            timestampSeconds: note.optLong("time") / 1000,
            url: link.url,
            medias: medias,
            notice: notice
        )
    }

    private static func pickVideo(_ note: VideoJSONObject) -> (url: String, quality: String)? {
        guard let stream = note.optObject("video")?.optObject("media")?.optObject("stream") else { return nil }
        for (key, label) in streamOrder {
            guard let first = stream.optArray(key)?.optObject(0) else { continue }
            let url = first.str("masterUrl").ifBlank(first.str("master_url"))
            if !url.isBlank { return (url, label) }
        }
        return nil
    }

    private static func rawImages(_ note: VideoJSONObject) -> [String] {
        imageUrls(note.optArray("imageList")) { $0.str("urlDefault").ifBlank($0.str("url")) }
    }

    private static func imageUrls(_ array: VideoJSONArray?, pick: (VideoJSONObject) -> String) -> [String] {
        guard let array else { return [] }
        return (0..<array.count).compactMap { array.optObject($0).map(pick) }.filter { !$0.isBlank }
    }

    /// Converts every image and checks the origin copy exists, since the CDN gives 404 for an id it
    /// does not have. Better a watermark than a dead link. Parallel: atlases can be large.
    private func resolveImages(_ raws: [String], headers: [String: String]) async throws -> (urls: [String], fallbacks: Int) {
        var urls = raws
        var fallbacks = 0
        try await withThrowingTaskGroup(of: (Int, String, Bool).self) { group in
            for (index, raw) in raws.enumerated() {
                group.addTask {
                    let clean = Self.watermarkFreeOrRaw(raw)
                    if clean == raw { return (index, raw, false) }
                    let missing = try await probeMissing(clean, headers: headers)
                    return (index, missing ? raw : clean, missing)
                }
            }
            for try await (index, url, fellBack) in group {
                urls[index] = url
                if fellBack { fallbacks += 1 }
            }
        }
        return (urls, fallbacks)
    }

    /// Only 404 and 410 mean missing. A timeout or a CDN that refuses HEAD does not.
    private func probeMissing(_ url: String, headers: [String: String]) async throws -> Bool {
        do {
            let status = try await http.request(url, method: "HEAD", headers: headers).status
            return status == 404 || status == 410
        } catch is VideoParseException {
            Self.logger.warning("小红书去水印原图探测失败（按可用处理）")
            return false
        }
    }

    /// `host/<bucket>/<hash>/<id>!<spec>` becomes `<cdn>/<id>`. Unchanged when there is no id.
    static func watermarkFreeOrRaw(_ raw: String) -> String {
        guard let scheme = raw.range(of: "://") else { return raw }
        let rest = raw[scheme.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return raw }
        let path = rest[rest.index(after: slash)...].components(separatedBy: "/").dropFirst(2).joined(separator: "/")
        let id = path.prefix { $0 != "!" }
        return id.isBlank ? raw : "\(imageCdn)/\(id)"
    }

    private static func isLoginWall(_ url: String) -> Bool {
        loginWallMarkers.contains { url.contains($0) }
    }

    private static func query(_ link: DetectedVideoLink) -> String {
        guard let mark = link.url.firstIndex(of: "?") else { return "" }
        let query = link.url[link.url.index(after: mark)...]
        return query.isBlank ? "" : "?\(query)"
    }

    private static func exploreHeaders(_ cookie: String) -> [String: String] {
        var headers = ["User-Agent": VideoHttp.uaChrome, "accept": accept, "Referer": referer]
        if !cookie.isBlank { headers["Cookie"] = cookie }
        return headers
    }

    private static func discoveryHeaders(_ cookie: String) -> [String: String] {
        var headers = [
            "User-Agent": VideoHttp.uaIphone,
            "accept": accept,
            "Referer": referer,
            "origin": home,
            "x-requested-with": "XMLHttpRequest",
            "sec-fetch-site": "same-origin",
            "sec-fetch-mode": "cors",
            "sec-fetch-dest": "empty",
        ]
        if !cookie.isBlank { headers["Cookie"] = cookie }
        return headers
    }

    private static func mediaHeaders(_ cookie: String) -> [String: String] {
        var headers = ["User-Agent": VideoHttp.uaChrome, "Referer": referer]
        if !cookie.isBlank { headers["Cookie"] = cookie }
        return headers
    }
}
