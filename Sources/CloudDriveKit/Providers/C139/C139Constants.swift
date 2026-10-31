// Ported from YunX-Desktop (MIT): data/network/C139Constants.kt.
// Endpoints, header values and cookie rules follow that file. The headers were captured from a
// working session there; they are not documented by the service.
import Foundation

public enum C139Constants {
    /// WebView login page (139 Cloud, phone number login). Loaded with a mobile UA there.
    public static let loginURL = "https://yun.139.com/m/#/login"
    /// Fast-login cookies (Os_SSo_Sid, RMKEY) live on this domain.
    public static let cookieDomain = "https://mail.10086.cn"
    /// `authorization` and `ud_id` live on this domain.
    public static let cookieDomainBackup = "https://yun.139.com"

    static let shareBase = "https://share-kd-njs.yun.139.com"
    static let shareListURL = "\(shareBase)/yun-share/richlifeApp/devapp/IOutLink/getOutLinkInfoV6"
    static let shareLinkURL = "\(shareBase)/yun-share/richlifeApp/devapp/IOutLink/dlFromOutLinkV3"
    static let shareGeneralURL = "\(shareBase)/yun-share/richlifeApp/devapp/IOutLink/getOutLinkGeneral"
    static let transferCreateURL = "\(shareBase)/yun-share/richlifeApp/devapp/IBatchOprTask/createOuterLinkBatchOprTask"
    static let transferQueryURL = "\(shareBase)/yun-share/richlifeApp/devapp/IBatchOprTask/queryBatchOprTaskDetail"

    /// Fixed AES-128-CBC key of the share endpoints, the same for every account.
    static let shareAESKey = "PVGDwmcvfs1uV3d1"

    static let cloudBase = "https://personal-kd-njs.yun.139.com"
    static let fileListURL = "\(cloudBase)/hcy/file/list"
    static let fileUpdateURL = "\(cloudBase)/hcy/file/update"
    /// Creates folders and pre-creates uploads; `type` tells them apart.
    static let fileCreateURL = "\(cloudBase)/hcy/file/create"
    static let batchMoveURL = "\(cloudBase)/hcy/file/batchMove"
    static let batchTrashURL = "\(cloudBase)/hcy/recyclebin/batchTrash"
    static let downloadURL = "\(cloudBase)/hcy/file/getDownloadUrl"
    static let taskGetURL = "\(cloudBase)/hcy/task/get"
    static let outlinkCreateURL = "https://yun.139.com/orchestration/personalCloud-rebuild/outlink/v1.0/getOutLink"
    static let quotaURL = "https://user-njs.yun.139.com/user/disk/quota/detail"

    // Channel and context headers. Without all of them the gateway answers 404 with code 04000005.
    static let yunChannelSource = "10000034"
    static let mcloudVersion = "7.17.9"
    static let mcloudClient = "10701"
    static let mcloudChannel = "1000101"
    static let yunModuleType = "100"
    static let m4cSrc = "10002"
    static let m4cCaller = "PC"
    static let xDeviceinfo = "||9|7.17.9|chrome|116.0.0.0|2cdaf7ada9e353c70eba99092e177991||windows 10||zh-CN|||"
    static let xClientInfo = "||9|7.17.9|chrome|116.0.0.0|2cdaf7ada9e353c70eba99092e177991||windows 10||zh-CN|||dW5kZWZpbmVk||"

    // Share endpoints answer 9530 when any of these is missing.
    static let shareXDeviceinfo = "||3|12.27.0|||||chrome 150.0.0.0|360X444|zh-cn|||"
    static let shareXHuaweiChannelsrc = "10245500"
    static let shareXMMSource = "0002"
    /// Must look like a browser; an HTTP library UA is rejected.
    public static let shareMobileUserAgent = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36"
    /// Desktop UA: the web page only issues `authorization` to it. Also the download UA.
    public static let pcUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    public static let rootShareDirectory = "root"
    /// Root of the personal drive, as the list, move and create calls take it.
    public static let rootDirectoryId = "/"

    /// Both login forms count: Os_SSo_Sid with RMKEY, or a web `authorization`.
    public static func isValidCookie(_ cookie: String?) -> Bool {
        guard let cookie, !cookie.isBlankText else { return false }
        if C139CookieUtil.value(of: "authorization", in: cookie) != nil { return true }
        return ["Os_SSo_Sid", "RMKEY"].allSatisfy { C139CookieUtil.value(of: $0, in: cookie) != nil }
    }

    /// `Basic cGM6...`; nil when absent.
    public static func extractAuthorization(_ cookie: String?) -> String? {
        guard let cookie else { return nil }
        return C139CookieUtil.value(of: "authorization", in: cookie)
    }

    /// The full phone number the share calls need: ORCHES-I-ACCOUNT-ENCRYPT, then authorization, then Login_UserNumber.
    public static func extractAccountFull(_ cookie: String?) -> String? {
        guard let cookie, !cookie.isBlankText else { return nil }
        for pair in C139CookieUtil.pairs(cookie) where pair.name == "ORCHES-I-ACCOUNT-ENCRYPT" && !pair.value.isBlankText {
            if let decoded = C139CookieUtil.decodeBase64(pair.value), !decoded.isBlankText { return decoded }
        }
        if let authorization = extractAuthorization(cookie), let account = C139CookieUtil.account(fromAuthorization: authorization) {
            return account
        }
        return C139CookieUtil.value(of: "Login_UserNumber", in: cookie)
    }

    /// A display name: masked number first, then the decoded number, then Login_UserNumber.
    public static func extractAccount(_ cookie: String?) -> String? {
        guard let cookie, !cookie.isBlankText else { return nil }
        if let masked = C139CookieUtil.value(of: "ORCHES-I-ACCOUNT-SIMPLIFY", in: cookie) { return masked }
        if let encrypted = C139CookieUtil.value(of: "ORCHES-I-ACCOUNT-ENCRYPT", in: cookie) {
            if let decoded = C139CookieUtil.decodeBase64(encrypted), !decoded.isBlankText { return decoded }
            return encrypted
        }
        return C139CookieUtil.value(of: "Login_UserNumber", in: cookie)
    }
}

enum C139CookieUtil {
    static func pairs(_ cookie: String) -> [(name: String, value: String)] {
        cookie.components(separatedBy: ";").compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = trimmed.firstIndex(of: "=") else { return nil }
            return (String(trimmed[..<equals]), String(trimmed[trimmed.index(after: equals)...]))
        }
    }

    /// First non-blank value of `name`.
    static func value(of name: String, in cookie: String) -> String? {
        pairs(cookie).first { $0.name == name && !$0.value.isBlankText }?.value
    }

    /// Java's decoder accepts missing padding; Foundation's does not.
    static func decodeBase64(_ text: String) -> String? {
        var padded = text.trimmingCharacters(in: .whitespacesAndNewlines)
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// `Basic base64(pc:<account>:<authToken>)`.
    static func account(fromAuthorization authorization: String) -> String? {
        var body = authorization.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("Basic") { body.removeFirst(5) }
        guard let decoded = decodeBase64(body) else { return nil }
        let parts = decoded.components(separatedBy: ":")
        guard parts.count > 1, !parts[1].isBlankText else { return nil }
        return parts[1]
    }
}
