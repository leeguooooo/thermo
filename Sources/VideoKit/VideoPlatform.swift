import Foundation

/// Supported video platforms. A platform needs only a Cookie, never a directory tree.
///
/// An empty `loginUrl` means parsing works anonymously. Raw values match YunX's enum names so a
/// stored `platform` field stays readable.
public enum VideoPlatform: String, CaseIterable, Sendable, Equatable {
    case douyin = "DOUYIN"
    case xhs = "XHS"
    case kuaishou = "KUAISHOU"
    case weibo = "WEIBO"
    case acfun = "ACFUN"
    case bilibili = "BILIBILI"
    case pixiv = "PIXIV"

    public var displayName: String {
        switch self {
        case .douyin: return "抖音"
        case .xhs: return "小红书"
        case .kuaishou: return "快手"
        case .weibo: return "微博"
        case .acfun: return "AcFun"
        case .bilibili: return "哔哩哔哩"
        case .pixiv: return "Pixiv"
        }
    }

    public var loginUrl: String {
        switch self {
        // Must be /login itself: the site root redirects to a feed with a clipped login overlay.
        case .xhs: return "https://www.xiaohongshu.com/login"
        case .bilibili: return "https://passport.bilibili.com/login"
        case .pixiv: return "https://accounts.pixiv.net/login.php"
        default: return ""
        }
    }

    public var cookieDomain: String {
        switch self {
        case .xhs: return "xiaohongshu.com"
        case .bilibili: return "bilibili.com"
        case .pixiv: return "pixiv.net"
        default: return ""
        }
    }

    public var loginBenefit: String {
        switch self {
        case .xhs: return "小红书网页端要求登录后才能查看笔记，未登录解析会失败"
        case .bilibili: return "登录后可解析更高清晰度；未登录只能拿到很低清的单文件"
        case .pixiv: return "登录后可解析全部作品（含 R18 与受限作品）；未登录只能拿到一部分公开作品"
        default: return ""
        }
    }

    /// True when the platform has an account but no web login page. No platform uses this on desktop.
    public var manualCookieOnly: Bool { false }

    /// The mobile XHS site has no login page, so login always uses the desktop UA.
    public var loginUserAgent: String { VideoHttp.uaChrome }

    /// CSS width to force on the login page. XHS clips its confirm button when narrow.
    public var loginViewportWidth: Int? { self == .xhs ? 1280 : nil }

    public var needsLogin: Bool { !loginUrl.isBlank || manualCookieOnly }

    public static func fromName(_ name: String) -> VideoPlatform? { VideoPlatform(rawValue: name) }
}
