// Ported from YunX-Desktop (MIT): data/network/XunleiConstants.kt, XunleiDeviceFingerprint.kt,
// XunleiKouling.kt and the captcha_sign helpers in XunleiApi.kt / XunleiWebCredential.kt.
import CryptoKit
import Foundation

public enum XunleiConstants {
    static let authBase = "https://xluser-ssl.xunlei.com"
    static let panBase = "https://api-pan.xunlei.com"

    /// App credentials from the official client, used to exchange and refresh app tokens.
    public static let appClientID = "Xp6vsxz_7IYVw2BB"
    static let appClientSecret = "Xp6vsy4tN9toTVdMSpomVdXpRmES"
    /// Android identity used by captcha_sign.
    public static let appClientVersion = "8.31.0.9726"
    public static let appPackageName = "com.xunlei.downloadprovider"

    /// Ten salts in the order the app signature applies them.
    static let appCaptchaSalts = [
        "9uJNVj/wLmdwKrJaVj/omlQ",
        "Oz64Lp0GigmChHMf/6TNfxx7O9PyopcczMsnf",
        "Eb+L7Ce+Ej48u",
        "jKY0",
        "ASr0zCl6v8W4aidjPK5KHd1Lq3t+vBFf41dqv5+fnOd",
        "wQlozdg6r1qxh0eRmt3QgNXOvSZO6q/GXK",
        "gmirk+ciAvIgA/cxUUCema47jr/YToixTT+Q6O",
        "5IiCoM9B1/788ntB",
        "P07JH0h6qoM6TSUAK2aL9T5s2QBVeY9JWvalf",
        "+oK0AN",
    ]

    /// Downloads must use the official app UA: a browser UA makes the CDN answer 200 with the whole file.
    public static let appUserAgent = "ANDROID-com.xunlei.downloadprovider/8.31.0.9726 netWorkType/5G appid/40 "
        + "deviceName/Xiaomi_M2004j7ac deviceModel/M2004J7AC OSVersion/12 protocolVersion/301 "
        + "platformVersion/10 sdkVersion/512000 Oauth2Client/0.9 (Linux 4_14_186-perf-gddfs8vbb238b) (JAVA 0)"
    public static let webUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

    static let captchaInitURL = "\(authBase)/v1/shield/captcha/init"
    static let loginURL = "\(authBase)/xluser.core.login/v3/login"
    static let sendSMSURL = "\(authBase)/xluser.core.login/v3/sendsms"
    static let smsLoginURL = "\(authBase)/xluser.core.login/v3/smslogin"
    static let tokenURL = "\(authBase)/v1/auth/signin/token"
    static let refreshURL = "\(authBase)/v1/auth/token"

    static let filesURL = "\(panBase)/drive/v1/files"
    static let shareURL = "\(panBase)/drive/v1/share"
    static let shareDetailURL = "\(panBase)/drive/v1/share/detail"
    static let restoreURL = "\(panBase)/drive/v1/share/restore"
    static let tasksURL = "\(panBase)/drive/v1/tasks"
    static let moveURL = "\(panBase)/drive/v1/files:batchMove"
    static let trashURL = "\(panBase)/drive/v1/files:batchTrash"
    static let aboutURL = "\(panBase)/drive/v1/about"
    static let shareCreateURL = shareURL

    /// Root of the account. The share root is addressed by an empty id or "0".
    public static let rootDirectoryId = ""
    public static let tempDirectoryName = "YunX临时转存"

    static let sdkLoginUserAgent = "android-ok-http-client/xl-acc-sdk/version-5.1.3.513006"
    static let sdkSMSUserAgent = "android-ok-http-client/xl-acc-sdk/version-5.0.12.512000"
    static let captchaRedirectURI = "xlaccsdk01://xunlei.com/callback?state=harbor"
    static let panOrigin = "https://pan.xunlei.com"
}

/// App-channel and web-channel signing, plus the device fingerprint formula.
public enum XunleiSigner {
    /// `client_id + client_version + package_name + device_id + timestamp_ms`, then `md5(raw + salt)` for
    /// each of the ten salts, prefixed `1.`.
    public static func appCaptchaSign(deviceId: String, timestampMs: String) -> String {
        var hash = XunleiConstants.appClientID + XunleiConstants.appClientVersion
            + XunleiConstants.appPackageName + deviceId + timestampMs
        for salt in XunleiConstants.appCaptchaSalts { hash = md5Hex(hash + salt) }
        return "1.\(hash)"
    }

    /// Web version: nine salts and the host in place of the package name. Version and salts rotate
    /// together, roughly every 20 days; replace them as a set and keep the order.
    public static func webCaptchaSign(deviceId: String, timestampMs: Int64) -> String {
        var hash = XunleiWebAuth.clientID + XunleiWebAuth.webClientVersion + XunleiWebAuth.webSignHost
            + deviceId + String(timestampMs)
        for salt in XunleiWebAuth.webCaptchaSalts { hash = md5Hex(hash + salt) }
        return "1.\(hash)"
    }

    static func md5Hex(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha1Hex(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Web channel identity (pan.xunlei.com), which is a different OAuth client from the app.
public enum XunleiWebAuth {
    public static let clientID = "Xqp0kJBXWhwaTpB6"
    /// Stored in the credential so a refresh knows which client issued the token.
    public static let authType = "webToken"
    static let webClientVersion = "1.93.10"
    static let webPackageName = "pan.xunlei.com"
    static let webSignHost = "pan.xunlei.com"
    /// Server expiry is 300 s; the web page treats it as stale 30 s early.
    static let captchaTokenLifetime: TimeInterval = 270

    static let desktopUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    /// Client hints that must match `desktopUserAgent`; a UA without them reads as mobile and conflicts.
    static let desktopSecChUA = "\"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\""
    static let desktopSecChUAMobile = "?0"
    static let desktopSecChUAPlatform = "\"Windows\""

    /// Nine salts; the order matters.
    static let webCaptchaSalts = [
        "DVM8BRQfJWDsIE0JbH5GCUM0z0jU1yGymBTj4Eyloazv1F+w0G7ig",
        "T",
        "a1fUxfjOO1/dW++DpGupRgw9P93L",
        "aktKbp+/lQc3MvlMHIupt65LjAgJOL6ttMFvTKK+7+WKubSf9rT",
        "SB/ne9FQUnQmWz4Wuv9KqKfGOBOCUubpHpECxOHfD4hNoMclYA2Yq",
        "sOZFBQ8IMFy3OFjAIf/eA65iqFvS9TIKzLyrhiT6",
        "ZhJdLgL7MGh2GanboB0yk",
        "Osf",
        "v",
    ]
}

/// A device fingerprint. The host generates it once per install and keeps it; sharing one fingerprint
/// across users invites rate limiting for all of them.
public struct XunleiDevice: Sendable, Equatable {
    public let deviceId: String
    public let peerId: String

    private static let appID = "40"
    private static let appKey = "34a062aaa22f906fca4fefe9fb3a3021"

    public init(deviceId: String, peerId: String) {
        self.deviceId = deviceId
        self.peerId = peerId
    }

    /// `div101.` + id + md5(sha1(id + package + appid + app key)).
    public var deviceSign: String {
        let sha1 = XunleiSigner.sha1Hex(deviceId + XunleiConstants.appPackageName + Self.appID + Self.appKey)
        return "div101.\(deviceId)\(XunleiSigner.md5Hex(sha1))"
    }

    public static func generate() -> XunleiDevice {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    public static func generate<G: RandomNumberGenerator>(using generator: inout G) -> XunleiDevice {
        XunleiDevice(deviceId: randomHex(32, &generator), peerId: randomHex(32, &generator))
    }

    private static func randomHex<G: RandomNumberGenerator>(_ length: Int, _ generator: inout G) -> String {
        let digits = Array("0123456789abcdef")
        return String((0..<length).map { _ in digits[Int.random(in: 0..<16, using: &generator)] })
    }
}

/// Chinese share passwords ("口令") that stand for a share link plus passcode.
public enum XunleiKouling {
    static let jumpAPI = "https://api-shoulei-ssl.xunlei.com/xlppc.searcher.api/jump"
    /// The server checks the channel; without these it answers with a search page instead of the share.
    static let origin = "https://sl-m-ssl.xunlei.com"
    static let referer = "https://sl-m-ssl.xunlei.com/"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.5359.215 Safari/537.36 TBC/1.3.3.999 Thunder/12.4.4.3740"

    private static let maxLength = 64
    private static let decorations = CharacterSet(charactersIn: "「」『』【】《》〈〉“”‘’\"'`()（）[]{}<>.,，。;；:：!！?？、|")

    public static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: decorations)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Short text of letters and digits with at least one Chinese character. The caller must also have
    /// checked that it is not a share link.
    public static func looksLikeKouling(_ text: String) -> Bool {
        let value = normalize(text)
        if value.isEmpty || value.count > maxLength { return false }
        if !value.allSatisfy({ $0.isLetter || $0.isNumber }) { return false }
        return value.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    static func jumpURL(_ keyword: String) -> String {
        "\(jumpAPI)?noredirect=1&t=20&wd=\(HTTPClient.encodeQueryValue(keyword))&tn=15007414_5_dg&src=lm&ls=sm3016480&lm_extend=ctype:31"
    }

    /// `https://pan.xunlei.com/s/<id>?pwd=<pwd>` from a response `location`, dropping tracking parameters.
    public static func shareURL(fromLocation location: String?) -> String? {
        guard let location = location?.nonBlank,
              let found = location.range(of: #"pan\.xunlei\.com/s/([A-Za-z0-9_-]+)"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let id = String(location[found]).dropFirst("pan.xunlei.com/s/".count)
        let passcode = location.range(of: #"[?&]pwd=([A-Za-z0-9]+)"#, options: .regularExpression)
            .map { String(location[$0]).dropFirst(5) }
        guard let passcode, !passcode.isEmpty else { return "https://pan.xunlei.com/s/\(id)" }
        return "https://pan.xunlei.com/s/\(id)?pwd=\(passcode)"
    }
}
