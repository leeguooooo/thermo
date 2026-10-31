// Ported from YunX-Desktop (MIT): data/network/LanzouConstants.kt.
import Foundation

public enum LanzouConstants {
    /// Browser UA. The personal-drive endpoints and download nodes both expect the same one as the web pages.
    public static let webUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    public static let mydiskURL = "https://pc.woozooo.com/mydisk.php"
    /// The page that carries uid and vei.
    public static let mydiskFilesURL = "https://pc.woozooo.com/mydisk.php?item=files&action=index"
    public static let douploadURL = "https://pc.woozooo.com/doupload.php"
    public static let origin = "https://pc.woozooo.com"

    public static let accountsURL = "https://accounts.woozooo.com/accounts.php"
    public static let accountsOrigin = "https://accounts.woozooo.com"
    public static let loginRef = "pc.woozooo.com"

    /// folder_id -1 is the drive root.
    public static let rootFolderId = "-1"

    public static let maxFilePages = 1000
    public static let maxFolderPages = 500

    /// The download node refuses direct links without this cookie.
    public static let downIPCookie = "down_ip=1"

    /// Folder and file ids can collide in the personal drive, so listings prefix them.
    public static let folderPrefix = "d:"
    public static let filePrefix = "f:"

    /// Host used when a share carries only an id.
    public static let defaultShareBase = "https://pan.lanzoui.com"

    /// lanzou*, lan[zs]o[ux]; com, net, org and cn.
    private static let hostPattern = try! NSRegularExpression(
        pattern: #"^(?:[a-z0-9-]+\.)*(?:lanzou[a-z]?|lan[zs]o[ux])\.(?:com|net|org|cn)$"#, options: .caseInsensitive)

    public static func isLanzouHost(_ host: String) -> Bool {
        hostPattern.firstMatch(in: host, range: NSRange(host.startIndex..., in: host)) != nil
    }

    /// https, no fragment, no trailing slashes.
    public static func normalizeShareURL(_ url: String) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("http://") { text = "https://" + text.dropFirst("http://".count) }
        if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    public static func folderId(fromListingId id: String) -> String { id.hasPrefix(folderPrefix) ? String(id.dropFirst(folderPrefix.count)) : id }
    public static func fileId(fromListingId id: String) -> String { id.hasPrefix(filePrefix) ? String(id.dropFirst(filePrefix.count)) : id }
}
