// Ported from YunX-Desktop (MIT): data/network/Pan115Constants.kt.
//
// Pitfalls kept from the source notes: business APIs all live on webapi.115.com and POST as forms; write calls
// take `file_id` for files and `cate_id` (the list's `cid`) for folders; CDN links need the 900 second cookie
// from the link response, joined with the login cookie.
import Foundation

public enum Pan115Constants {
    static let apiBase = "https://webapi.115.com"

    public static let webLoginURL = "https://115.com/"
    static let shareHost = "https://115cdn.com"
    static let referer = "https://115.com/"
    static let downloadReferer = "https://115.com/"

    static let userInfoURL = "\(apiBase)/user/info?ct=json"
    static let filesURL = "\(apiBase)/files"
    static let indexInfoURL = "\(apiBase)/files/index_info?count_space_nums=1"
    static let fileAddURL = "\(apiBase)/files/add"
    static let fileMoveURL = "\(apiBase)/files/move"
    static let moveProgressURL = "\(apiBase)/files/move_progress"
    static let fileRenameURL = "\(apiBase)/files/batch_rename"
    static let fileDeleteURL = "\(apiBase)/rb/delete"
    /// Web direct link. Only small files; big ones answer 50028.
    static let fileDownloadURL = "\(apiBase)/files/download"
    /// The desktop client's encrypted link endpoint (see `Pan115Crypto`).
    static let appDownloadURL = "https://proapi.115.com/app/chrome/downurl"
    static let allowProtocolURL = "\(apiBase)/user/allow_protocol"
    static let shareSendURL = "\(apiBase)/share/send"
    static let shareUpdateURL = "\(apiBase)/share/updateshare"
    static let shareSnapURL = "\(apiBase)/share/snap"
    static let shareDownloadURL = "\(apiBase)/share/downurl"
    static let shareReceiveURL = "\(apiBase)/share/receive"

    static let personalAid = "1"
    public static let rootDirectoryId = "0"
    public static let pageLimit = 100
    public static let sharePageLimit = 100
    static let movePollMax = 20
    static let movePollIntervalNanoseconds: UInt64 = 400_000_000

    /// Temporary save root, shared in name with the other drives.
    public static let tempDirectoryName = DriveTempDirectory.name
    public static let tempSubdirectoryPrefix = "tr_"

    /// Desktop Chrome UA. 115 risk-checks non-browser UAs, so web calls look like the web page.
    public static let webUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"
    static let requestedWith = "XMLHttpRequest"

    /// Fallback for the client UA version. 115 rejects old versions with 50029, so the live value is fetched.
    static let clientUAVersionFallback = "36.0.1"
    /// `data.win.version_code` is the current Windows 115 browser version; no login needed.
    static let appVersionURL = "https://appversion.115.com/1/web/1.0/api/chrome"

    public static func clientUserAgent(version: String) -> String { "Mozilla/5.0 115Browser/\(version)" }

    /// A version like `36.0.1`; anything else (empty, too long, odd characters) is ignored.
    static func isPlausibleClientVersion(_ value: String) -> Bool {
        guard let first = value.first, first.isASCII, first.isNumber, value.count <= 16 else { return false }
        return value.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "." }
    }

    /// Login cookie fields worth keeping. alist's minimum working set is UID/CID/SEID/KID.
    public static let cookieKeepKeys: [String] = ["UID", "CID", "SEID", "KID", "PHPSESSID", "GST", "USERSESSIONID"]

    static let errnoLoginTimeout = 990001
    static let errnoNeedCode = 4100012
    static let errnoWrongCode = 4100008
    static let errnoShareGone = 4100026
    static let errnoEmptyFolder = 4100016
    static let errnoBusy = 990009
    static let errnoNeedConfirm = 800007
    /// Personal download: file exceeds the web limit.
    static let errnoWebSizeLimit = 50028
    /// Share download: client version judged too old.
    static let errnoClientTooOld = 50029

    /// alist: `https://115cdn.com/s/<code>?password=<code>&`
    static func shareReferer(shareCode: String, receiveCode: String) -> String {
        receiveCode.isBlankText ? "\(shareHost)/s/\(shareCode)" : "\(shareHost)/s/\(shareCode)?password=\(receiveCode)&"
    }

    /// Value of one field of a cookie like `UID=103616022_A1_169; CID=xxx`.
    public static func cookieValue(_ cookie: String, name: String) -> String? {
        for part in cookie.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("\(name)=") {
                let value = String(trimmed.dropFirst(name.count + 1))
                return value.isBlankText ? nil : value
            }
        }
        return nil
    }

    /// Only `UID` is required: SEID and KID are HttpOnly and rotate, so the server's 990001 is the better error.
    public static func hasLoginCookie(_ cookie: String) -> Bool { cookieValue(cookie, name: "UID") != nil }

    /// `UID` looks like `103616022_A1_<timestamp>`; the digits before the first underscore are the user id.
    public static func extractUserId(_ cookie: String) -> String? {
        cookieValue(cookie, name: "UID").flatMap { $0.split(separator: "_", omittingEmptySubsequences: false).first.map(String.init) }?.nonBlank
    }

    /// Joins the login cookie with the CDN cookie.
    public static func mergeCookies(_ parts: String...) -> String {
        parts.filter { !$0.isBlankText }.joined(separator: "; ")
    }

    /// Keeps only `cookieKeepKeys` (first occurrence wins) from a whole cookie string.
    public static func filterLoginCookies(_ raw: String) -> String {
        var kept: [(String, String)] = []
        for part in raw.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else { continue }
            let key = String(pair[..<equals])
            if cookieKeepKeys.contains(key), !kept.contains(where: { $0.0 == key }) {
                kept.append((key, String(pair[pair.index(after: equals)...])))
            }
        }
        return kept.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    /// Looks plausible when UID and SEID both have values. The server decides whether it is valid.
    public static func isValidCookie(_ cookie: String?) -> Bool {
        guard let cookie else { return false }
        return cookieValue(cookie, name: "UID") != nil && cookieValue(cookie, name: "SEID") != nil
    }

    /// The share session token is `<receive_code>|<sharer user_id>`: the sharer's id is needed to get a link
    /// and exists only in the snap response, so it travels in `ShareSession.accessToken`.
    static func encodeShareToken(receiveCode: String, userId: String) -> String { "\(receiveCode)|\(userId)" }

    /// A malformed token is read as the receive code with no user id.
    static func decodeShareToken(_ token: String) -> (receiveCode: String, userId: String) {
        guard let bar = token.firstIndex(of: "|") else { return (token, "") }
        return (String(token[..<bar]), String(token[token.index(after: bar)...]))
    }
}

/// Share validity codes, from ShareExpire.kt. 115's 5-day tier has no code of its own here (unknown).
public enum Pan115ShareExpire {
    public static let unknown = 0
    public static let forever = 101
    public static let oneDay = 102
    public static let threeDays = 103
    public static let sevenDays = 104
    public static let fifteenDays = 105

    /// `duration` is `-1` (forever) or a day count.
    public static func code(duration: String) -> Int {
        switch duration.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "-1": return forever
        case "1": return oneDay
        case "3": return threeDays
        case "7": return sevenDays
        case "15": return fifteenDays
        default: return unknown
        }
    }

    /// 115 reports validity as text like `15天` or `长期`.
    public static func code(text: String) -> Int {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return unknown }
        if value.contains("长期") || value.contains("永久") { return forever }
        let days = String(value.prefix { $0.isASCII && $0.isNumber })
        return days.isEmpty ? unknown : code(duration: days)
    }
}
