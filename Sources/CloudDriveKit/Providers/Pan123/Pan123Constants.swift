// Ported from YunX-Desktop (MIT): data/network/Pan123Constants.kt, Pan123LoginSupport.kt.
import Foundation

public enum Pan123Constants {
    static let loginBase = "https://user.123pan.cn"
    static let apiBase = "https://yun.123pan.cn"
    static let downloadBase = "https://www.123865.com"

    static let loginURL = "\(loginBase)/api/user/sign_in"
    /// Sign-in needs Origin and Referer on the user.123pan.cn site, or the risk control rejects it.
    static let signInOrigin = loginBase
    static let signInReferer = "\(loginBase)/"
    /// The sign-in endpoint wants app-version 132; the web pages use 3. They must not be mixed.
    static let appVersionSignIn = "132"

    static let shareGetURL = "\(apiBase)/b/api/share/get"
    static let shareDownloadInfoURL = "\(downloadBase)/b/api/share/download/info"
    static let fileListURL = "\(apiBase)/b/api/file/list/new"
    /// No /b/ in this path.
    static let fileDownloadInfoURL = "\(apiBase)/api/file/download_info"
    static let fileTrashURL = "\(apiBase)/b/api/file/trash"
    static let fileRenameURL = "\(apiBase)/b/api/file/rename"
    static let fileModPidURL = "\(apiBase)/b/api/file/mod_pid"
    /// 123 has no folder endpoint: upload_request with `type` 1 makes a folder.
    static let fileUploadRequestURL = "\(apiBase)/b/api/file/upload_request"
    static let shareCreateURL = "\(apiBase)/b/api/share/create"
    static let userInfoURL = "\(apiBase)/b/api/user/info"

    public static let webUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"
    static let dartUserAgent = "Dart/3.12 (dart:io)"
    static let platformWeb = "web"
    static let platformAndroid = "android"
    static let appVersionWeb = "3"
    static let appVersionAndroid = "39"

    /// Real CDN links must be downloaded with this Referer.
    public static let downloadReferer = "https://yun.123pan.cn/"
    public static let rootDirectoryId = "0"
    /// A share that never expires.
    public static let expirationForever = "2099-12-12T08:00:00+08:00"

    /// Digit 0-9 maps to the character at that index.
    static let signTable = Array("adefghlmyijnopkqrstubcvwsz")
    static let signOS = "web"
    static let signVersion = "3"
    /// The time sign is formatted from ts + 16 h in UTC (found by packet capture).
    static let signOffsetSeconds: Int64 = 57600

    static let redirectProbeLimit = 8192
    static let redirectHops = 5
    static let copyPollAttempts = 15
    static let maxSharePages = 50
}

/// Error mapping and token checks for sign-in. Server text is only used to classify, never shown,
/// because it can echo the account or the password.
enum Pan123LoginSupport {
    static let messageTooFrequent = "123 登录请求过于频繁，请稍后重试"
    static let messageFallback = "123 登录失败，请检查账号和密码后重试"
    static let messageVerifyRequired = "123 要求额外安全验证，请改用网页登录完成验证"

    private static let frequentKeywords = ["频繁", "频率", "次数", "稍后"]
    private static let verifyKeywords = ["验证码", "滑块", "安全验证", "验证失败", "captcha", "verify"]
    private static let frozenKeywords = ["冻结", "封禁", "封停", "注销", "禁用"]

    static func describeFailure(httpStatus: Int, code: Int, serverMessage: String) -> String {
        let message = serverMessage.lowercased()
        if (300...399).contains(httpStatus) { return "123 登录接口发生变化，请稍后重试" }
        if httpStatus == 429 { return messageTooFrequent }
        if httpStatus >= 500 { return "123 登录服务暂时不可用，请稍后重试" }
        if code == 429 { return messageTooFrequent }
        if frequentKeywords.contains(where: message.contains) { return messageTooFrequent }
        if verifyKeywords.contains(where: message.contains) { return messageVerifyRequired }
        if frozenKeywords.contains(where: message.contains) { return "123 账号暂时不可登录，请先在官方客户端检查账号状态" }
        return messageFallback
    }

    /// Non-empty, at most 16384 characters, and no control characters that could pollute a header.
    static func isValidToken(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 16384 && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}
