import Foundation

/// Pixiv illustrations and manga, one original image per page.
///
/// Parsing runs anonymously too, but R18 and restricted works need a login. Ugoira and novels are
/// not supported. `i.pximg.net` refuses requests without the pixiv Referer.
public struct PixivParser: VideoParser {
    public let platform = VideoPlatform.pixiv
    private static let referer = "https://www.pixiv.net/"
    private let http: VideoHttp

    public init(http: VideoHttp = VideoHttp()) {
        self.http = http
    }

    private static func apiHeaders(_ cookie: String) -> [String: String] {
        var headers = mediaHeaders(cookie)
        headers["Accept"] = "application/json"
        return headers
    }

    private static func mediaHeaders(_ cookie: String) -> [String: String] {
        var headers = ["User-Agent": VideoHttp.uaChrome, "Referer": referer]
        if !cookie.isBlank { headers["Cookie"] = cookie }
        return headers
    }

    /// Probes behaviour, not Cookie names: visitors get a `PHPSESSID` too. Logged-out
    /// `/dashboard/works` redirects to a `return_to=` URL, and that redirect must not be followed
    /// because the target is cleartext. A failed probe passes, since refusing a valid Cookie
    /// would stop the account being saved at all.
    public func validateCookie(_ cookie: String) async throws -> String? {
        if cookie.isBlank { return nil }
        let response: VideoResponse
        do {
            response = try await http.request(
                "https://www.pixiv.net/dashboard/works",
                headers: Self.apiHeaders(cookie),
                followRedirects: false
            )
        } catch is VideoParseException {
            return ""
        }
        guard (300...399).contains(response.status) else { return "" }
        let location = response.header("Location") ?? ""
        let loginWall = location.contains("return_to=") || location.contains("/login")
            || location.contains("accounts.pixiv.net")
        return loginWall ? nil : ""
    }

    public func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let info = try await http.getJson(
            "https://www.pixiv.net/ajax/illust/\(link.id)",
            headers: Self.apiHeaders(cookie),
            what: "Pixiv 作品信息"
        )
        if info.optBoolean("error") { throw Self.apiError(info.optString("message"), cookie: cookie) }
        guard let body = info.optObject("body") else {
            throw VideoParseException(.unknown, "Pixiv 作品信息缺少 body")
        }
        // illustType: 0 illustration, 1 manga, 2 ugoira.
        if body.optInt("illustType") == 2 {
            throw VideoParseException(.unsupported, "Pixiv 动图（ugoira）需要合成 GIF，当前版本暂不支持")
        }

        let pages = try await http.getJson(
            "https://www.pixiv.net/ajax/illust/\(link.id)/pages",
            headers: Self.apiHeaders(cookie),
            what: "Pixiv 原图列表"
        ).optArray("body")

        let title = body.optString("title")
        let base = VideoFileName.base(title, fallback: "pixiv_\(link.id)")
        let media = { (url: String, name: String) in
            VideoMedia(url: url, kind: .image, fileName: name, headers: Self.mediaHeaders(cookie), quality: "原图")
        }

        var medias: [VideoMedia] = []
        if let pages {
            for index in 0..<pages.count {
                let original = pages.optObject(index)?.optObject("urls")?.optString("original") ?? ""
                if original.isBlank { continue }
                medias.append(media(original, "\(base)_\(index + 1).\(Self.extensionOf(original))"))
            }
        }
        if medias.isEmpty {
            let original = body.optObject("urls")?.optString("original") ?? ""
            if !original.isBlank { medias.append(media(original, "\(base).\(Self.extensionOf(original))")) }
        }
        guard let first = medias.first else {
            throw VideoParseException(.notFound, "Pixiv 未返回任何可下载的原图")
        }

        return VideoParseResult(
            platform: platform,
            title: title,
            author: body.optString("userName"),
            cover: first.url,
            text: body.optString("description"),
            timestampSeconds: Self.parseCreateDate(body.optString("createDate")),
            url: "https://www.pixiv.net/artworks/\(link.id)",
            medias: medias
        )
    }

    /// One `error` field covers missing works, dead sessions and restricted works.
    private static func apiError(_ message: String, cookie: String) -> VideoParseException {
        let lower = message.lowercased()
        let needsLogin = lower.contains("login") || lower.contains("session")
        let kind: VideoParseErrorKind
        if lower.contains("not found") {
            kind = .notFound
        } else if needsLogin || cookie.isBlank {
            kind = .unsupported
        } else {
            kind = .blocked
        }
        if needsLogin {
            return VideoParseException(kind, "Pixiv 登录态已失效，请到「账号」页重新粘贴 Cookie")
        }
        if kind == .unsupported {
            return VideoParseException(kind, "该作品需要登录后才能解析（多为 R18 或受限作品），请在「账号」页粘贴浏览器里的 Cookie")
        }
        return VideoParseException(kind, "Pixiv 作品信息返回错误：\(message)")
    }

    private static func parseCreateDate(_ text: String) -> Int64 {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXX"
        return formatter.date(from: text).map { Int64($0.timeIntervalSince1970) } ?? 0
    }

    private static func extensionOf(_ url: String) -> String {
        let path = url.prefix { $0 != "?" }
        guard let name = path.split(separator: "/", omittingEmptySubsequences: false).last,
              let dot = name.lastIndex(of: ".") else { return "jpg" }
        let ext = name[name.index(after: dot)...]
        return !ext.isBlank && ext.count <= 4 ? ext.lowercased() : "jpg"
    }
}
