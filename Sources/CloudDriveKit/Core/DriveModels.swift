// Ported from YunX-Desktop (MIT): data/network/model/ShareModels.kt.
import Foundation

/// Drives a share link can belong to. Baidu is deliberately absent.
public enum DrivePlatform: String, Sendable, CaseIterable {
    case quark, uc, xunlei, c139, pan123, pan115, guangya, ilanzou, lanzou
}

/// An opaque login secret, usually a Cookie header value.
/// Not Codable and redacted when printed: the host owns storage and must keep it in the Keychain.
public struct DriveCredential: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let value: String
    public init(_ value: String) { self.value = value }
    public var isBlank: Bool { value.isBlankText }
    public var description: String { "DriveCredential(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// Called when a response rotates a credential. `previous` identifies which account to update.
public typealias CredentialUpdateHandler = @Sendable (_ updated: DriveCredential, _ previous: DriveCredential) -> Void

public enum DriveAccountState: Sendable, Equatable {
    /// No credential, or it lacks the fields the drive requires.
    case signedOut
    /// The credential looks complete but the account lookup failed, so it may have expired.
    case unverified
    case signedIn(nickname: String)
}

public struct DriveQuota: Sendable, Equatable {
    public let used: Int64
    public let total: Int64
    public init(used: Int64, total: Int64) {
        self.used = used
        self.total = total
    }
}

public struct ParsedShareLink: Sendable, Equatable, CustomStringConvertible {
    public let shareId: String
    public let passcode: String?
    public let platform: DrivePlatform
    public init(shareId: String, passcode: String?, platform: DrivePlatform) {
        self.shareId = shareId
        self.passcode = passcode
        self.platform = platform
    }
    public var description: String { "ParsedShareLink(\(platform.rawValue), \(shareId))" }
}

/// One opened share. `accessToken` is a provider value such as Quark's stoken.
public struct ShareSession: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let platform: DrivePlatform
    public let shareId: String
    public let accessToken: String
    public let title: String
    public init(platform: DrivePlatform, shareId: String, accessToken: String, title: String) {
        self.platform = platform
        self.shareId = shareId
        self.accessToken = accessToken
        self.title = title
    }
    public var description: String { "ShareSession(\(platform.rawValue), \(shareId), <redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: ["platform": platform, "shareId": shareId]) }
}

public struct DriveFile: Sendable, Equatable {
    public let id: String
    public let name: String
    public let size: Int64
    public let isDirectory: Bool
    public let parentId: String
    /// Per-file share token; empty outside share listings on drives that have none.
    public let fileToken: String
    public let modifiedAt: String
    public init(id: String, name: String, size: Int64, isDirectory: Bool, parentId: String, fileToken: String = "", modifiedAt: String = "") {
        self.id = id
        self.name = name
        self.size = size
        self.isDirectory = isDirectory
        self.parentId = parentId
        self.fileToken = fileToken
        self.modifiedAt = modifiedAt
    }
}

/// Everything a download engine needs. Headers can hold cookies, so printing redacts them.
public struct ResolvedLink: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let url: URL
    public let headers: [String: String]
    public let fileId: String
    public let filename: String
    public let size: Int64
    /// Temporary directory to pass to `cleanup` after the download ends; nil when there is none.
    public let cleanupDirectoryId: String?
    public let isHLS: Bool
    public init(url: URL, headers: [String: String], fileId: String, filename: String, size: Int64, cleanupDirectoryId: String? = nil, isHLS: Bool = false) {
        self.url = url
        self.headers = headers
        self.fileId = fileId
        self.filename = filename
        self.size = size
        self.cleanupDirectoryId = cleanupDirectoryId
        self.isHLS = isHLS
    }
    public var description: String { "ResolvedLink(\(fileId), \(filename), \(size) bytes, <redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: ["fileId": fileId, "filename": filename, "size": size]) }
}

/// The folder saved shares pass through in the account, on every drive that needs one.
public enum DriveTempDirectory {
    public static let name = "Thermo临时转存"
}

public struct DriveCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shareListing = DriveCapabilities(rawValue: 1 << 0)
    /// Shares can be opened and listed without an account. Resolving a file may still throw
    /// `DriveError.loginRequired` on drives that only hand out links to accounts.
    public static let guestShareAccess = DriveCapabilities(rawValue: 1 << 1)
    public static let ownFiles = DriveCapabilities(rawValue: 1 << 2)
    public static let saveToDrive = DriveCapabilities(rawValue: 1 << 3)
}

public struct ShareResolveOptions: Sendable, Equatable {
    /// Try a direct share link first, then fall back to saving through a temporary directory.
    public var preferNoSave: Bool
    /// The caller already ran a batch space check.
    public var skipSpaceCheck: Bool
    public init(preferNoSave: Bool = true, skipSpaceCheck: Bool = false) {
        self.preferNoSave = preferNoSave
        self.skipSpaceCheck = skipSpaceCheck
    }
}

public enum DriveError: Error, Equatable, LocalizedError, Sendable {
    /// A server or protocol failure. `message` is shown to the user; `code` is the drive's code, or 0.
    case api(message: String, code: Int = 0)
    case invalidShareLink
    case loginRequired
    case unsupported(platform: DrivePlatform, feature: String)
    case providerUnavailable(DrivePlatform)
    case timedOut(String)
    case insufficientSpace(required: Int64, available: Int64)
    case transport(code: Int)

    public var errorDescription: String? {
        switch self {
        case .api(let message, _): return message
        case .invalidShareLink: return "无法识别分享链接"
        case .loginRequired: return "请先登录后再试"
        case .unsupported(let platform, let feature): return "\(platform.rawValue) 不支持\(feature)"
        case .providerUnavailable(let platform): return "暂不支持 \(platform.rawValue)"
        case .timedOut(let message): return message
        case .insufficientSpace(let required, let available):
            return "剩余空间不足：需要 \(SpaceGuard.formatBytes(required))，当前可用 \(SpaceGuard.formatBytes(available))"
        case .transport(let code): return "网络请求失败（\(code)）"
        }
    }
}

extension String {
    var isBlankText: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func ifBlank(_ fallback: String) -> String { isBlankText ? fallback : self }
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
    var nonBlank: String? { isBlankText ? nil : self }
}
