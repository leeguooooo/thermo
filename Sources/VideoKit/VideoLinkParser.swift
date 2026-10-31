import Foundation

/// A recognised link. `kind` uses the platform's own word. Short links have an empty `id` until
/// the redirect is followed and the target is recognised again.
public struct DetectedVideoLink: Sendable, Equatable {
    public var platform: VideoPlatform
    public var kind: String
    public var id: String
    public var url: String
    public var isShortLink: Bool

    public init(platform: VideoPlatform, kind: String, id: String, url: String, isShortLink: Bool = false) {
        self.platform = platform
        self.kind = kind
        self.id = id
        self.url = url
        self.isShortLink = isShortLink
    }
}

/// Finds a video platform link in pasted text. Only the link is matched, never the surrounding
/// text, and bare numeric ids are refused because they collide with drive extraction codes.
public enum VideoLinkParser {
    private struct Rule: @unchecked Sendable {
        let platform: VideoPlatform
        let kind: String
        let regex: NSRegularExpression

        init(_ platform: VideoPlatform, _ kind: String, _ pattern: String) {
            self.platform = platform
            self.kind = kind
            regex = VideoLinkParser.compile(pattern, options: .caseInsensitive)
        }
    }

    /// ICU's `\s` and `\d` cover all of Unicode while Java's are ASCII. A full-width space must
    /// not end a URL here, or the same paste would parse differently from YunX.
    private static func compile(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // ICU accepts a nested class, so `[0-9]` is valid inside `[A-Za-z\d]` too.
        let ascii = pattern
            .replacingOccurrences(of: "\\d", with: "[0-9]")
            .replacingOccurrences(of: "[^\\s]", with: "[^ \\t\\n\\x0B\\f\\r]")
        return try! NSRegularExpression(pattern: ascii, options: options)
    }

    private static let urlRegex = compile(#"https?://[^\s]+"#)
    private static let trailing = Set("。，,；;)]}\"'、！？…")

    /// Order is priority: short links before long ones.
    private static let rules: [Rule] = [
        // Douyin
        Rule(.douyin, "short", #"v\.douyin\.com/[A-Za-z0-9_\-]+"#),
        Rule(.douyin, "short", #"jx\.douyin\.com/[A-Za-z0-9_\-]+"#),
        Rule(.douyin, "video", #"(?:www\.)?douyin\.com/(video|note)/(\d{10,})"#),
        Rule(.douyin, "video", #"douyin\.com/[^\s]*[?&]modal_id=(\d{10,})"#),
        Rule(.douyin, "video", #"iesdouyin\.com/share/(?:slides|video|note)/(\d{10,})"#),
        Rule(.douyin, "video", #"m\.douyin\.com/share/(?:slides|video|note)/(\d{10,})"#),
        Rule(.douyin, "video", #"jingxuan\.douyin\.com/m/(?:slides|video|note)/(\d{10,})"#),
        // Xiaohongshu
        Rule(.xhs, "short", #"xhslink\.(?:com|cn)/[A-Za-z0-9._?%&+=/#@\-]+"#),
        Rule(.xhs, "note", #"xiaohongshu\.com/(?:explore|discovery/item|discovery)/([0-9a-zA-Z]{10,})"#),
        // Kuaishou
        Rule(.kuaishou, "short", #"v\.kuaishou\.com/[A-Za-z\d._?%&+\-=/#]+"#),
        Rule(.kuaishou, "photo", #"(?:www\.)?kuaishou\.com/(?:short-video|fw/photo|fw/long-video)/([A-Za-z\d]+)"#),
        Rule(.kuaishou, "photo", #"(?:www\.)?kuaishou\.com/f/([A-Za-z\d]+)"#),
        Rule(.kuaishou, "photo", #"(?:v\.m\.)?chenzhongtech\.com/fw/(?:photo|long-video)/([A-Za-z\d]+)"#),
        // Weibo
        Rule(.weibo, "tv", #"weibo\.com/tv/show/\d{4}:\d+\?mid=(\d+)"#),
        Rule(.weibo, "fid", #"video\.weibo\.com/show\?fid=(\d+:\d+)"#),
        Rule(.weibo, "status", #"weibo\.cn/(?:status|statuses|detail)/([0-9a-zA-Z]+)"#),
        Rule(.weibo, "status", #"weibo\.com/\d+/([0-9a-zA-Z]{6,})"#),
        // AcFun
        Rule(.acfun, "ac", #"acfun\.cn/.*(?:ac=|/ac)(\d+)"#),
        // Bilibili
        Rule(.bilibili, "short", #"b23\.tv/[A-Za-z\d]+"#),
        Rule(.bilibili, "short", #"bili2233\.cn/[A-Za-z\d]+"#),
        Rule(.bilibili, "video", #"bilibili\.com/video/(BV[0-9a-zA-Z]{10}|av\d+)"#),
        // Pixiv
        Rule(.pixiv, "artwork", #"pixiv\.net/(?:[a-z]{2}/)?artworks/(\d+)"#),
        Rule(.pixiv, "artwork", #"pixiv\.net/member_illust\.php\?[^\s]*illust_id=(\d+)"#),
    ]

    public static func parse(_ text: String) -> DetectedVideoLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = NSRange(trimmed.startIndex..., in: trimmed)
        guard let found = urlRegex.firstMatch(in: trimmed, range: whole),
              let foundRange = Range(found.range, in: trimmed) else { return nil }
        var url = String(trimmed[foundRange])
        while let last = url.last, trailing.contains(last) { url.removeLast() }

        let range = NSRange(url.startIndex..., in: url)
        for rule in rules {
            guard let match = rule.regex.firstMatch(in: url, range: range) else { continue }
            let isShort = rule.kind == "short"
            var id = ""
            if !isShort, match.numberOfRanges > 1 {
                for group in (1..<match.numberOfRanges).reversed() {
                    guard let groupRange = Range(match.range(at: group), in: url), !url[groupRange].isBlank else { continue }
                    id = String(url[groupRange])
                    break
                }
            }
            return DetectedVideoLink(platform: rule.platform, kind: rule.kind, id: id, url: url, isShortLink: isShort)
        }
        return nil
    }

    public static func looksLikeVideoLink(_ text: String) -> Bool { parse(text) != nil }
}
