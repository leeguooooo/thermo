// Ported from YunX-Desktop (MIT): data/network/QuarkConstants.kt and QuarkCookieUtil in QuarkApi.kt.
import Foundation

public enum QuarkConstants {
    /// PC client UA for the WebView login page only.
    public static let loginUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 QuarkPC/6.0.8.649"
    /// Required on API and download requests.
    public static let apiUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch"

    public static let loginURL = "https://pan.quark.cn/?fr=pc&platform=pc"
    public static let cookieDomain = "https://pan.quark.cn"
    public static let accountInfoURL = "https://pan.quark.cn/account/info"

    static let apiBase = "https://drive-pc.quark.cn"
    static let shareTokenURL = "\(apiBase)/1/clouddrive/share/sharepage/token?pr=ucpro&fr=pc"
    static let sharePasswordURL = "\(apiBase)/1/clouddrive/share/password?pr=ucpro&fr=pc"
    static let shareDetailURL = "\(apiBase)/1/clouddrive/share/sharepage/detail?pr=ucpro&fr=pc"
    static let downloadURL = "\(apiBase)/1/clouddrive/file/download?pr=ucpro&fr=pc&sys=win32&ve=3.23.2"
    static let fileURL = "\(apiBase)/1/clouddrive/file?pr=ucpro&fr=pc"
    static let cloudFileSortURL = "\(apiBase)/1/clouddrive/file/sort?pr=ucpro&fr=pc"
    static let saveURL = "\(apiBase)/1/clouddrive/share/sharepage/save?pr=ucpro&fr=pc"
    static let taskURL = "\(apiBase)/1/clouddrive/task?pr=ucpro&fr=pc"
    static let deleteURL = "\(apiBase)/1/clouddrive/file/delete?pr=ucpro&fr=pc&uc_param_str="
    static let renameURL = "\(apiBase)/1/clouddrive/file/rename?pr=ucpro&fr=pc&uc_param_str="
    static let moveURL = "\(apiBase)/1/clouddrive/file/move?pr=ucpro&fr=pc&uc_param_str="
    static let shareCreateURL = "\(apiBase)/1/clouddrive/share?pr=ucpro&fr=pc&uc_param_str="
    static let shareInfoURL = "\(apiBase)/1/clouddrive/share/password?pr=ucpro&fr=pc&uc_param_str="
    static let quotaURL = "\(apiBase)/1/clouddrive/member?pr=ucpro&fr=pc&fetch_subscribe=true&_ch=home"
    static let configURL = "\(apiBase)/1/clouddrive/config?pr=ucpro&fr=pc"

    public static let rootDirectoryId = "0"
    public static let tempDirectoryName = "YunX临时转存"
    public static let tempSubdirectoryPrefix = "tr_"
    public static let downloadReferer = "https://pan.quark.cn/"
    /// __puus lasts about 3 hours; refresh at 90 minutes.
    public static let puusRefreshInterval: TimeInterval = 90 * 60

    public static func isValidCookie(_ cookie: String?) -> Bool {
        guard let cookie else { return false }
        return cookie.contains("__pus=") && cookie.contains("__puus=")
    }
}

/// Merges and strips __puus and __pus, which sign download links.
public enum QuarkCookieUtil {
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
