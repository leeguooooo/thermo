import CloudDriveKit
import Foundation
import MediaToolsKit
import Security
import ThermoL10n
import VideoKit

/// One signed-in account. Lives only inside the Keychain item; printing it shows no secret.
struct YunXAccount: Codable, Identifiable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var id: String
    /// `quark`, `pan115`, or `video:BILIBILI`: the same names YunX backups use.
    var platform: String
    var fields: [String: String]
    var updatedAt: Int64
    var isPrimary: Bool

    var nickname: String { fields["nickname"] ?? "" }
    var description: String { "YunXAccount(\(platform), <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["platform": platform]) }

    static let videoPrefix = "video:"
    var videoPlatform: VideoPlatform? {
        platform.hasPrefix(Self.videoPrefix) ? VideoPlatform.fromName(String(platform.dropFirst(Self.videoPrefix.count))) : nil
    }
    var drivePlatform: DrivePlatform? { DrivePlatform(rawValue: platform) }
}

protocol YunXSecretBackend: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

enum YunXKeychainError: LocalizedError {
    case status(OSStatus)
    var errorDescription: String? {
        if case let .status(code) = self { return tr("Keychain error %1$@", String(code)) }
        return nil
    }
}

/// All accounts as one generic-password item, so a change is atomic and macOS asks at most once.
struct YunXKeychainBackend: YunXSecretBackend {
    /// One item each: `vault`, plus the download list and tracker list, which can hold passcodes and passkeys.
    var account = "vault"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.thermo.yunx.accounts",
         kSecAttrAccount as String: account]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw YunXKeychainError.status(status) }
        return result as? Data
    }

    func write(_ data: Data) throws {
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw YunXKeychainError.status(update) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw YunXKeychainError.status(add) }
    }
}

/// Moves between backup field names and the one string each provider takes as its credential.
enum YunXCredentialCodec {
    static func credential(_ platform: DrivePlatform, fields: [String: String]) -> DriveCredential {
        func field(_ name: String) -> String { fields[name] ?? "" }
        switch platform {
        case .quark, .uc, .c139, .pan115, .lanzou: return DriveCredential(field("cookie"))
        case .pan123: return DriveCredential(field("accessToken"))
        case .xunlei:
            return XunleiCredential(accessToken: field("accessToken"), refreshToken: field("refreshToken"), deviceId: field("deviceId"),
                                    captchaToken: field("captchaToken"), userId: field("userId"), nickname: field("nickname"),
                                    authType: field("authType")).driveCredential
        case .guangya:
            let device = field("deviceId").isEmpty ? nil : GuangYaDevice(deviceId: field("deviceId"), deviceSign: field("deviceSign"))
            return GuangYaCredential(accessToken: field("accessToken"), refreshToken: field("refreshToken"), device: device,
                                     accessExpiresAt: Int64(field("accessExpiresAt")) ?? 0).driveCredential
        case .ilanzou:
            return ILanzouCredential(appToken: field("appToken"), uuid: field("uuid"), userId: field("userId")).credential
        }
    }

    /// What to store for a credential. `base` keeps profile fields the credential does not carry.
    static func fields(_ platform: DrivePlatform, credential: DriveCredential, base: [String: String] = [:]) -> [String: String] {
        var out = base
        switch platform {
        case .quark, .uc, .pan115, .lanzou: out["cookie"] = credential.value
        case .c139:
            out["cookie"] = credential.value
            if let authorization = C139Constants.extractAuthorization(credential.value) { out["authorization"] = authorization }
        case .pan123: out["accessToken"] = credential.value
        case .xunlei:
            guard let parsed = XunleiCredential(credential) else { break }
            out["accessToken"] = parsed.accessToken
            out["refreshToken"] = parsed.refreshToken
            out["deviceId"] = parsed.deviceId
            out["captchaToken"] = parsed.captchaToken
            out["userId"] = parsed.userId
            out["authType"] = parsed.authType
        case .guangya:
            let parsed = GuangYaCredential(credential)
            out["accessToken"] = parsed.accessToken
            out["refreshToken"] = parsed.refreshToken
            out["deviceId"] = parsed.device?.deviceId ?? ""
            out["deviceSign"] = parsed.device?.deviceSign ?? ""
            out["accessExpiresAt"] = String(parsed.accessExpiresAt)
        case .ilanzou:
            guard let parsed = ILanzouCredential(credential) else { break }
            out["appToken"] = parsed.appToken
            out["uuid"] = parsed.uuid
            out["userId"] = parsed.userId
        }
        return out
    }
}

/// Every read and write of account secrets. Nothing here touches a file, a default or a log.
final class YunXVault: @unchecked Sendable {
    private let backend: YunXSecretBackend
    private let lock = NSLock()
    private let now: @Sendable () -> Int64

    init(backend: YunXSecretBackend = YunXKeychainBackend(),
         now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.backend = backend
        self.now = now
    }

    private func load() throws -> [YunXAccount] {
        guard let data = try backend.read() else { return [] }
        return try JSONDecoder().decode([YunXAccount].self, from: data)
    }

    private func mutate<T>(_ change: (inout [YunXAccount]) -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var accounts = try load()
        let result = change(&accounts)
        try backend.write(try JSONEncoder().encode(accounts))
        return result
    }

    func accounts() throws -> [YunXAccount] {
        lock.lock()
        defer { lock.unlock() }
        return try load()
    }

    /// The account requests use: the primary one, else the first of that platform.
    func active(_ platform: String) throws -> YunXAccount? {
        let matching = try accounts().filter { $0.platform == platform }
        return matching.first(where: \.isPrimary) ?? matching.first
    }

    @discardableResult
    func add(platform: String, fields: [String: String], key: String) throws -> YunXAccount {
        try mutate { accounts in
            let stamp = now()
            if let index = accounts.firstIndex(where: { $0.platform == platform && Self.same($0.fields, fields, key: key) }) {
                accounts[index].fields.merge(fields) { _, new in new }
                accounts[index].updatedAt = stamp
                return accounts[index]
            }
            let isFirst = !accounts.contains { $0.platform == platform }
            let account = YunXAccount(id: UUID().uuidString, platform: platform, fields: fields, updatedAt: stamp, isPrimary: isFirst)
            accounts.append(account)
            return account
        }
    }

    private static func same(_ left: [String: String], _ right: [String: String], key: String) -> Bool {
        if let a = left[key], !a.isEmpty, a == right[key] { return true }
        if let a = left["nickname"], !a.isEmpty, a == right["nickname"] { return true }
        return false
    }

    func remove(id: String) throws {
        try mutate { accounts in
            guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
            let removed = accounts.remove(at: index)
            if removed.isPrimary, let next = accounts.firstIndex(where: { $0.platform == removed.platform }) {
                accounts[next].isPrimary = true
            }
        }
    }

    func setPrimary(id: String) throws {
        try mutate { accounts in
            guard let platform = accounts.first(where: { $0.id == id })?.platform else { return }
            for index in accounts.indices where accounts[index].platform == platform {
                accounts[index].isPrimary = accounts[index].id == id
            }
        }
    }

    /// A drive rotated a session; finds the account by its old credential.
    func rotate(previous: DriveCredential, updated: DriveCredential) throws {
        try mutate { accounts in
            for index in accounts.indices {
                guard let platform = accounts[index].drivePlatform,
                      YunXCredentialCodec.credential(platform, fields: accounts[index].fields) == previous else { continue }
                accounts[index].fields = YunXCredentialCodec.fields(platform, credential: updated, base: accounts[index].fields)
                accounts[index].updatedAt = now()
                return
            }
        }
    }

    /// Fills in a name the first login could not fetch. Changes nothing else, including `updatedAt`.
    func setNickname(id: String, _ nickname: String) throws {
        try mutate { accounts in
            guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
            accounts[index].fields["nickname"] = nickname
        }
    }

    /// Merges one backup row: same video id or same credential replaces, anything else is a new account.
    func upsert(_ row: BackupAccount, key: String) throws {
        try mutate { accounts in
            if let index = accounts.firstIndex(where: { $0.platform == row.platform && Self.same($0.fields, row.fields, key: key) }) {
                accounts[index].fields.merge(row.fields) { _, new in new }
                accounts[index].updatedAt = row.updatedAt
                return
            }
            let hasPrimary = accounts.contains { $0.platform == row.platform && $0.isPrimary }
            accounts.append(YunXAccount(id: UUID().uuidString, platform: row.platform, fields: row.fields, updatedAt: row.updatedAt,
                                        isPrimary: !hasPrimary))
        }
    }
}

/// Plugs the vault into the encrypted backup. Thermo has no GitHub integration, so a token in an
/// imported backup is dropped instead of being kept.
struct YunXBackupStore: BackupCredentialStore {
    let vault: YunXVault

    func accounts() async throws -> [BackupAccount] {
        try vault.accounts().map { account in
            var fields = account.fields
            if account.videoPlatform != nil { fields["id"] = account.id }
            return BackupAccount(platform: account.platform, fields: fields, updatedAt: account.updatedAt,
                                 isPrimary: account.videoPlatform != nil ? account.isPrimary : nil)
        }
    }

    func upsert(_ account: BackupAccount) async throws {
        try vault.upsert(account, key: YunXBackupStore.key(account.platform))
    }

    static func key(_ platform: String) -> String {
        switch DrivePlatform(rawValue: platform) {
        case .pan123?, .xunlei?, .guangya?: return "accessToken"
        case .ilanzou?: return "appToken"
        default: return "cookie"
        }
    }

    func gitHubToken() async throws -> String? { nil }
    func setGitHubToken(_ token: String) async throws {}
    func isKnownVideoPlatform(_ name: String) -> Bool { VideoPlatform.fromName(name) != nil }
}
