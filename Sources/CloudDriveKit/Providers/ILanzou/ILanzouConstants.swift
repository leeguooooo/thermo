// Ported from YunX-Desktop (AGPL-3.0): data/network/ILanzouConstants.kt.
import Foundation

public enum ILanzouConstants {
    static let apiBase = "https://apis.ilanzou.com"
    public static let webSite = "https://www.ilanzou.com"

    public static let downloadReferer = "\(webSite)/"
    public static let downloadOrigin = webSite

    public static let webUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    static let devType = "6"
    static let devModel = "chrome"
    static let devVersion = "125"
    static let pageSize = 60

    static let getUUIDURL = "\(apiBase)/unproved/getUuid"
    static let loginURL = "\(apiBase)/unproved/login"
    static let accountMapURL = "\(apiBase)/proved/user/account/map"
    static let fileListURL = "\(apiBase)/proved/record/file/list"
    static let folderSaveURL = "\(apiBase)/proved/file/folder/save"
    static let folderEditURL = "\(apiBase)/proved/file/folder/edit"
    static let fileEditURL = "\(apiBase)/proved/file/edit"
    static let folderMoveURL = "\(apiBase)/proved/file/folder/move"
    static let fileDeleteURL = "\(apiBase)/proved/file/delete"
    static let fileRedirectURL = "\(apiBase)/unproved/file/redirect"

    /// Share pages talk to apix, not to the personal-drive host.
    static let shareAPIBase = "https://apix.ilanzou.com"
    static let shareListURL = "\(shareAPIBase)/unproved/share/list"
    static let shareRedirectURL = "\(shareAPIBase)/unproved/file/redirect"
    static let shareDevModel = "Chrome"
    static let fileTransferURL = "\(apiBase)/proved/file/transfer"
    static let fileTransferNumURL = "\(apiBase)/proved/file/transfer/num"

    public static let rootFolderId = "0"
    static let aesKey = "lanZouY-disk-app"
    public static let folderPrefix = "d:"
    public static let filePrefix = "f:"

    // ILanzouResolveRepository.transferFile: up to 30 polls, 500 ms apart.
    static let transferPollAttempts = 30
    static let transferPollInterval: UInt64 = 500_000_000

    static func isValidUUID(_ value: String) -> Bool { value.range(of: "^[A-Za-z0-9_-]{8,128}$", options: .regularExpression) != nil }
    static func isValidToken(_ value: String) -> Bool {
        value.count >= 16 && value.range(of: "^[A-Za-z0-9._~+/=:!%&?\\-]+$", options: .regularExpression) != nil
    }
}

/// The values every authenticated call needs. Encoded as `appToken=…; uuid=…; userId=…`
/// so it travels as a `DriveCredential`; the host keeps it in the Keychain.
public struct ILanzouCredential: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let appToken: String
    public let uuid: String
    /// Builds the download id; may be empty until an account lookup fills it.
    public let userId: String

    public init(appToken: String, uuid: String, userId: String = "") {
        self.appToken = appToken
        self.uuid = uuid
        self.userId = userId
    }

    public init?(_ credential: DriveCredential) {
        var fields: [String: String] = [:]
        for part in credential.value.components(separatedBy: ";") {
            let pair = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = pair.firstIndex(of: "=") else { continue }
            fields[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        guard let token = fields["appToken"], let uuid = fields["uuid"],
              ILanzouConstants.isValidToken(token), ILanzouConstants.isValidUUID(uuid) else { return nil }
        self.init(appToken: token, uuid: uuid, userId: fields["userId"] ?? "")
    }

    public var credential: DriveCredential {
        DriveCredential("appToken=\(appToken); uuid=\(uuid); userId=\(userId)")
    }

    func with(userId: String) -> ILanzouCredential { ILanzouCredential(appToken: appToken, uuid: uuid, userId: userId) }

    public var description: String { "ILanzouCredential(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
