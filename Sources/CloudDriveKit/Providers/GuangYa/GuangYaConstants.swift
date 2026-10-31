// Ported from YunX-Desktop (AGPL-3.0): data/network/GuangYaConstants.kt.
import Foundation

public enum GuangYaConstants {
    static let clientId = "aMe-8VSlkrbQXpUR"

    static let apiBase = "https://api.guangyapan.com"
    static let accountBase = "https://account.guangyapan.com"
    public static let webSite = "https://www.guangyapan.com"

    /// Download links require this Referer.
    public static let downloadReferer = "\(webSite)/"
    public static let webUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    // Account API headers.
    static let clientVersion = "0.0.1"
    static let sdkVersion = "9.1.3"
    static let protocolVersion = "301"
    /// Already percent-encoded in the source and sent as is.
    static let deviceModel = "chrome%2F131.0.0.0"
    static let deviceName = "PC-Chrome"
    static let osVersion = "Win32"
    static let platformVersion = "1"

    static let authTokenURL = "\(accountBase)/v1/auth/token"
    static let userMeURL = "\(accountBase)/v1/user/me"
    static let captchaInitURL = "\(accountBase)/v1/shield/captcha/init"
    static let signinURL = "\(accountBase)/v1/auth/signin"
    static let signupURL = "\(accountBase)/v1/auth/signup"
    static let verificationURL = "\(accountBase)/v1/auth/verification"
    static let verificationVerifyURL = "\(accountBase)/v1/auth/verification/verify"

    static let getAssetsURL = "\(apiBase)/assets/v1/get_assets"
    static let shareSummaryURL = "\(apiBase)/userres/v1/get_share_summary"
    static let shareAccessTokenURL = "\(apiBase)/userres/v1/get_share_access_token"
    static let shareFilesURL = "\(apiBase)/userres/v1/get_share_page_files_list"
    static let shareDownloadURL = "\(apiBase)/userres/v1/get_share_download_url"
    static let restoreShareURL = "\(apiBase)/userres/v1/restore_share"
    static let shareFileURL = "\(apiBase)/userres/v1/share_file"

    static let fileListURL = "\(apiBase)/userres/v1/file/get_file_list"
    static let createDirURL = "\(apiBase)/userres/v1/file/create_dir"
    static let renameURL = "\(apiBase)/userres/v1/file/rename"
    static let moveFileURL = "\(apiBase)/userres/v1/file/move_file"
    static let deleteFileURL = "\(apiBase)/userres/v1/file/delete_file"
    static let resDownloadURL = "\(apiBase)/userres/v1/get_res_download_url"
    static let taskStatusURL = "\(apiBase)/userres/v1/get_task_status"

    /// The share root and the drive root are both the empty string.
    public static let rootDirectoryId = ""
    static let pageSize = 100
    /// Task polling waits this long before every poll, at most `taskMaxPolls` times.
    static let taskDelayNanoseconds: UInt64 = 750_000_000
    static let taskMaxPolls = 80
    /// Folder name used for restricted shares. Kept from the source so leftovers are recognisable.
    static let tempDirectoryPrefix = "AsterLink临时转存_"

    private static func hex(_ count: Int) -> String {
        let digits = Array("0123456789abcdef")
        return String((0..<count).map { _ in digits[Int.random(in: 0..<16)] })
    }

    public static func newDeviceId() -> String { hex(32) }

    /// `wdi10.<deviceId><32 hex>`.
    public static func newDeviceSign(deviceId: String) -> String { "wdi10.\(deviceId)\(hex(32))" }

    /// X-Device-Id: the 32 characters after the first "." of the sign, else the fallback.
    static func deviceId(fromSign sign: String, fallback: String) -> String {
        guard let dot = sign.firstIndex(of: ".") else { return fallback }
        let rest = sign[sign.index(after: dot)...]
        return rest.count >= 32 ? String(rest.prefix(32)) : fallback
    }

    /// Regenerated for every request.
    static func newTraceparent() -> String { "00-\(hex(32))-\(hex(16))-01" }
}
