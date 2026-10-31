// Ported from YunX-Desktop (MIT): data/network/ShareLinkParser.kt. Baidu and GitHub are left out.
import Foundation

/// Finds the share link in pasted text and hands it to the provider for its drive.
public struct ShareLinkRouter: Sendable {
    private let providers: [DrivePlatform: any CloudDriveProvider]

    public init(providers: [any CloudDriveProvider]) {
        self.providers = Dictionary(providers.map { ($0.platform, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func route(_ text: String) throws -> (link: ParsedShareLink, provider: any CloudDriveProvider) {
        guard let link = Self.parse(text) else { throw DriveError.invalidShareLink }
        guard let provider = providers[link.platform] else { throw DriveError.providerUnavailable(link.platform) }
        return (link, provider)
    }

    private struct Rule {
        let platform: DrivePlatform
        let id: NSRegularExpression
        var urlPasscode = ShareLinkRouter.defaultUrlPasscode
    }

    // Every pattern is a literal covered by tests.
    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }
    private static func link(_ pattern: String) -> NSRegularExpression { regex(pattern, options: .caseInsensitive) }

    fileprivate static let defaultUrlPasscode = regex(#"[?&]pwd=([A-Za-z0-9]+)"#)
    private static let url = regex(#"https?://[^\s]+"#)
    private static let textPasscode = regex(#"(?:提取码|访问码|密码)[：:]\s*([A-Za-z0-9]{4,8})"#)
    private static let pan115UrlPasscode = regex(#"[?&]password=([A-Za-z0-9]+)"#)
    private static let lanzouUrlPasscode = link(#"[?&](?:pwd|pass|passcode|password)=([A-Za-z0-9]+)"#)
    private static let pan115Command = link(#"115(?:cdn|rc)?\.com/(sw[A-Za-z0-9]{8,})-([A-Za-z0-9]{4,8})"#)

    // Order matters: ilanzou must run before lanzou, and the 115 command form after the /s/ form.
    private static let rulesBefore115Command: [Rule] = [
        Rule(platform: .quark, id: link(#"pan\.quark\.cn/s/([A-Za-z0-9]+)"#)),
        Rule(platform: .uc, id: link(#"drive\.uc\.cn/s/([A-Za-z0-9]+)"#)),
        Rule(platform: .xunlei, id: link(#"pan\.xunlei\.com/s/([A-Za-z0-9_-]+)"#)),
        Rule(platform: .c139, id: link(#"yun\.139\.com/shareweb/.*?/w/i/([A-Za-z0-9_-]+)"#)),
        Rule(platform: .pan123, id: link(#"123(?:865|pan)\.(?:com|cn)/s/([A-Za-z0-9]+-[A-Za-z0-9]+)"#)),
        Rule(platform: .pan123, id: link(#"share\.123pan\.cn/123pan/([A-Za-z0-9-]+)"#)),
        Rule(platform: .pan123, id: link(#"api/srr\?sk=([A-Za-z0-9-]+)"#)),
        Rule(platform: .pan115, id: link(#"115(?:cdn|rc)?\.com/s/(sw[A-Za-z0-9]+)"#), urlPasscode: pan115UrlPasscode),
    ]
    private static let rulesAfter115Command: [Rule] = [
        Rule(platform: .guangya, id: link(#"guangyapan\.com/s/([A-Za-z0-9_-]+)"#)),
        Rule(platform: .ilanzou, id: link(#"(?:^|[/.])ilanzou\.(?:com|net|org|cn)/s/([A-Za-z0-9_-]+)"#), urlPasscode: lanzouUrlPasscode),
        Rule(platform: .lanzou, id: link(#"(?:^|[/.])(?:lanzou[a-z0-9-]*|lan[zs]o[ux])\.(?:com|net|org|cn)/([A-Za-z0-9]+)"#), urlPasscode: lanzouUrlPasscode),
    ]

    private static func captures(_ regex: NSRegularExpression, in text: String) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    /// Extracts the share id and passcode from a link or a whole share message.
    public static func parse(_ text: String) -> ParsedShareLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var found = firstURL(in: trimmed) else { return nil }
        while let last = found.last, "。，,；;)]}\"'".contains(last) { found.removeLast() }
        func apply(_ rules: [Rule]) -> ParsedShareLink? {
            for rule in rules {
                guard let id = captures(rule.id, in: found)?.first else { continue }
                let passcode = captures(rule.urlPasscode, in: found)?.first ?? captures(textPasscode, in: trimmed)?.first
                return ParsedShareLink(shareId: id, passcode: passcode, platform: rule.platform)
            }
            return nil
        }
        if let link = apply(rulesBefore115Command) { return link }
        if let parts = captures(pan115Command, in: found), parts.count == 2 {
            return ParsedShareLink(shareId: parts[0], passcode: parts[1], platform: .pan115)
        }
        return apply(rulesAfter115Command)
    }

    private static func firstURL(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        return url.firstMatch(in: text, range: range).flatMap { Range($0.range, in: text) }.map { String(text[$0]) }
    }
}
