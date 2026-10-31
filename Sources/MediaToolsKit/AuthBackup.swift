import Foundation

public struct BackupAccount: Sendable, Equatable {
    /// `quark`, `pan115`, or `video:BILIBILI` for a video platform.
    public var platform: String
    /// Credential and profile strings, under the same names YunX backups use.
    public var fields: [String: String]
    public var updatedAt: Int64
    /// Video accounts only.
    public var isPrimary: Bool?

    public init(platform: String, fields: [String: String], updatedAt: Int64, isPrimary: Bool? = nil) {
        self.platform = platform
        self.fields = fields
        self.updatedAt = updatedAt
        self.isPrimary = isPrimary
    }
}

/// What the backup reads from and restores to; CloudDriveKit's account stores plug in here.
public protocol BackupCredentialStore: Sendable {
    func accounts() async throws -> [BackupAccount]
    func upsert(_ account: BackupAccount) async throws
    func gitHubToken() async throws -> String?
    func setGitHubToken(_ token: String) async throws
    func isKnownVideoPlatform(_ name: String) -> Bool
}

public enum AuthBackupError: Error, Equatable, Sendable {
    case invalidBackup
    case encodingFailed
}

/// Exports stay encrypted: unlike YunX there is no way to write a plaintext backup.
/// Plain JSON can still be imported, because YunX could produce it. Baidu is not ported.
public struct AuthBackupManager: Sendable {
    static let appTag = "yunx_auth_backup"
    static let version = 1
    static let videoPrefix = "video:"

    /// platform to the field that proves it is logged in, and every string field the backup carries.
    static let schema: [String: (credential: String, fields: [String])] = [
        "quark": ("cookie", ["cookie", "nickname"]),
        "uc": ("cookie", ["cookie", "nickname"]),
        "xunlei": ("accessToken", ["accessToken", "refreshToken", "deviceId", "captchaToken", "nickname", "authType"]),
        "c139": ("cookie", ["cookie", "authorization", "nickname"]),
        "pan123": ("accessToken", ["accessToken", "account", "nickname"]),
        "pan115": ("cookie", ["cookie", "nickname"]),
        "guangya": ("accessToken", ["accessToken", "refreshToken", "deviceId", "deviceSign", "account", "nickname"]),
        "ilanzou": ("appToken", ["appToken", "uuid", "account", "password", "userId", "nickname"]),
        "lanzou": ("cookie", ["cookie", "nickname"]),
    ]
    static let videoFields = ["id", "cookie", "nickname", "remark"]

    private let store: BackupCredentialStore
    private let now: @Sendable () -> Int64

    public init(store: BackupCredentialStore) {
        self.init(store: store, now: { Int64(Date().timeIntervalSince1970 * 1000) })
    }

    init(store: BackupCredentialStore, now: @escaping @Sendable () -> Int64) {
        self.store = store
        self.now = now
    }

    public func export(password: String, onlyLoggedIn: Bool = true) async throws -> String {
        guard password.utf16.count >= 8 else { throw AuthCryptoError.passwordTooShort }
        return try AuthCrypto.encrypt(try await exportJSON(onlyLoggedIn: onlyLoggedIn), password: password)
    }

    func exportJSON(onlyLoggedIn: Bool) async throws -> String {
        var accounts: [[String: Any]] = []
        for account in try await store.accounts() {
            if account.platform.hasPrefix(Self.videoPrefix) {
                guard Self.present(account.fields["cookie"]) else { continue }
                var item: [String: Any] = ["platform": account.platform, "updatedAt": account.updatedAt, "isPrimary": account.isPrimary ?? false]
                for key in Self.videoFields { item[key] = account.fields[key] ?? "" }
                accounts.append(item)
            } else if let schema = Self.schema[account.platform] {
                guard !onlyLoggedIn || Self.present(account.fields[schema.credential]) else { continue }
                var item: [String: Any] = ["platform": account.platform, "updatedAt": account.updatedAt]
                for key in schema.fields { item[key] = account.fields[key] ?? "" }
                accounts.append(item)
            }
        }
        var root: [String: Any] = ["app": Self.appTag, "version": Self.version, "exportedAt": now(), "accounts": accounts]
        if let token = try? await store.gitHubToken(), Self.present(token) { root["githubToken"] = token }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            throw AuthBackupError.encodingFailed
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Returns how many credentials were restored.
    public func `import`(_ content: String, password: String? = nil) async throws -> Int {
        if let password, !password.isEmpty {
            return try await importJSON(try AuthCrypto.decrypt(content, password: password))
        }
        return try await importJSON(content)
    }

    func importJSON(_ json: String) async throws -> Int {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              root["app"] as? String == Self.appTag else { throw AuthBackupError.invalidBackup }
        var count = 0
        for object in root["accounts"] as? [Any] ?? [] {
            guard let item = object as? [String: Any], let platform = item["platform"] as? String else { continue }
            let updatedAt = (item["updatedAt"] as? NSNumber)?.int64Value ?? now()
            if platform.hasPrefix(Self.videoPrefix) {
                let name = String(platform.dropFirst(Self.videoPrefix.count))
                guard store.isKnownVideoPlatform(name), Self.present(Self.string(item["cookie"])) else { continue }
                var fields = Self.strings(item, keys: Self.videoFields)
                if !Self.present(fields["id"]) { fields["id"] = name }
                try await store.upsert(BackupAccount(
                    platform: platform, fields: fields, updatedAt: updatedAt, isPrimary: (item["isPrimary"] as? NSNumber)?.boolValue ?? false))
                count += 1
            } else if let schema = Self.schema[platform], Self.present(Self.string(item[schema.credential])) {
                try await store.upsert(BackupAccount(platform: platform, fields: Self.strings(item, keys: schema.fields), updatedAt: updatedAt))
                count += 1
            }
        }
        // A failed token restore must not fail the accounts; an old backup without one leaves the device's token alone.
        if let token = Self.string(root["githubToken"]), Self.present(token), (try? await store.setGitHubToken(token)) != nil {
            count += 1
        }
        return count
    }

    public static func defaultFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "yunx_auth_backup_\(formatter.string(from: date)).yunx"
    }

    /// Owner-only, atomic. Refuses anything that is not ciphertext.
    public static func save(_ content: String, to target: URL) throws {
        guard AuthCrypto.isEncrypted(content) else { throw AuthBackupError.invalidBackup }
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard FileManager.default.createFile(atPath: staging.path, contents: Data(content.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(staging.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private static func present(_ value: String?) -> Bool {
        !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func strings(_ item: [String: Any], keys: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, string(item[$0]) ?? "") })
    }
}
