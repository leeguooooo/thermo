// Ported from YunX-Desktop (MIT): data/network/UCConstants.kt and UCCookieUtil in UCApi.kt.
import Foundation

public enum UCConstants {
    /// Web UA used on ordinary signed-in requests and downloads.
    public static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    /// uc-cloud-drive client UA, used for the member (quota), file sort list and cloud download calls.
    public static let cloudUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/1.6.1 Chrome/100.0.4896.160 Electron/18.3.5.16-b62cf9c50d Safari/537.36 Channel/ucpan_other_ch"
    /// Guest (signed-out) client UA. The guest path is screened harder than the signed-in one.
    public static let guestUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
    /// Sent with `guestUserAgent`.
    public static let guestSecChUA = "\"Not=A?Brand\";v=\"99\", \"Chromium\";v=\"100\", \"Google Chrome\";v=\"100\""

    public static let webOrigin = "https://drive.uc.cn"
    /// Required on download requests; without it the OSS link is throttled to about 100 KB/s.
    public static let downloadReferer = "\(webOrigin)/"
    public static let loginURL = "https://drive.uc.cn/"
    public static let cookieDomain = "https://drive.uc.cn"
    public static let accountInfoURL = "https://drive.uc.cn/account/info"

    static let apiBase = "https://pc-api.uc.cn"
    static let shareTokenURL = "\(apiBase)/1/clouddrive/share/sharepage/token?pr=UCBrowser&fr=pc"
    static let shareDetailURL = "\(apiBase)/1/clouddrive/share/sharepage/v2/detail?pr=UCBrowser&fr=pc"
    static let transferShareDetailURL = "\(apiBase)/1/clouddrive/transfer_share/detail?entry=ft&fr=pc&pr=UCBrowser"
    static let downloadURL = "\(apiBase)/1/clouddrive/file/download?entry=ft&fr=pc&pr=UCBrowser"
    static let cloudDownloadURL = "\(apiBase)/1/clouddrive/file/download"
    static let playURL = "\(apiBase)/1/clouddrive/file/v2/play/project?pr=UCBrowser&fr=pc"
    static let barePlayURL = "\(apiBase)/1/clouddrive/file/v2/play/project"
    static let videoPreviewURL = "\(apiBase)/1/clouddrive/share/sharepage/video_preview"
    static let fileURL = "\(apiBase)/1/clouddrive/file?pr=UCBrowser&fr=pc"
    static let saveURL = "\(apiBase)/1/clouddrive/share/sharepage/save?pr=UCBrowser&fr=pc"
    static let taskURL = "\(apiBase)/1/clouddrive/task?pr=UCBrowser&fr=pc"
    static let cloudFileSortURL = "\(apiBase)/1/clouddrive/file/sort?pr=UCBrowser&fr=pc"
    static let renameURL = "\(apiBase)/1/clouddrive/file/rename?pr=UCBrowser&fr=pc"
    static let moveURL = "\(apiBase)/1/clouddrive/file/move?pr=UCBrowser&fr=pc"
    static let deleteURL = "\(apiBase)/1/clouddrive/file/delete?pr=UCBrowser&fr=pc"
    static let shareCreateURL = "\(apiBase)/1/clouddrive/share?pr=UCBrowser&fr=pc"
    static let shareInfoURL = "\(apiBase)/1/clouddrive/share/password?pr=UCBrowser&fr=pc"
    static let configURL = "\(apiBase)/1/clouddrive/config?pr=UCBrowser&fr=pc"
    static let quotaURL = "\(apiBase)/1/clouddrive/member?pr=UCBrowser&fr=pc&fetch_subscribe=true&_ch=home"

    public static let rootDirectoryId = "0"
    public static let tempDirectoryName = DriveTempDirectory.name
    /// __puus lasts about 3 hours; refresh at 90 minutes.
    public static let puusRefreshInterval: TimeInterval = 90 * 60

    public static func isValidCookie(_ cookie: String?) -> Bool {
        guard let cookie else { return false }
        return cookie.contains("__pus=") && cookie.contains("__puus=")
    }
}

/// Merges and strips __puus and __pus, which sign download links.
public enum UCCookieUtil {
    private static let tracked: Set<String> = ["__puus", "__pus"]

    public static func merge(_ original: String, setCookies: [String]) -> String {
        var cookie = original
        for setCookie in setCookies {
            let pair = pairPart(setCookie)
            guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else { continue }
            let name = String(pair[..<equals])
            if tracked.contains(name) {
                cookie = setOrReplace(cookie, name: name, value: String(pair[pair.index(after: equals)...]))
            }
        }
        return cookie
    }

    /// Dropping __puus makes the server issue a new one.
    public static func withoutPuus(_ cookie: String) -> String {
        split(cookie).filter { !$0.hasPrefix("__puus=") }.joined(separator: "; ")
    }

    static func pairPart(_ setCookie: String) -> String {
        String(setCookie.prefix { $0 != ";" }).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func split(_ cookie: String) -> [String] {
        cookie.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func setOrReplace(_ cookie: String, name: String, value: String) -> String {
        var parts = split(cookie)
        let pair = "\(name)=\(value)"
        if let index = parts.firstIndex(where: { $0.hasPrefix("\(name)=") }) {
            parts[index] = pair
        } else {
            parts.append(pair)
        }
        return parts.joined(separator: "; ")
    }
}
