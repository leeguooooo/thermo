import CryptoKit
import Darwin
import Foundation

/// One Claude Code account on this Mac: `~/.claude`, or a `~/.claude-<name>` folder that Claude Code
/// uses through its own `CLAUDE_CONFIG_DIR`. Sign-ins stay where Claude Code keeps them.
public struct ClaudeProfile: Identifiable, Equatable, Sendable {
    public var name: String
    public var directory: String
    public var isDefault: Bool
    public var email: String?
    public var organization: String?
    public var billing: String?
    /// nil when the Keychain could not answer.
    public var signedIn: Bool?
    public var liveSessions: Int
    public var lastUsed: Date?

    public init(name: String, directory: String, isDefault: Bool, email: String? = nil, organization: String? = nil,
                billing: String? = nil, signedIn: Bool?, liveSessions: Int, lastUsed: Date? = nil) {
        self.name = name
        self.directory = directory
        self.isDefault = isDefault
        self.email = email
        self.organization = organization
        self.billing = billing
        self.signedIn = signedIn
        self.liveSessions = liveSessions
        self.lastUsed = lastUsed
    }

    public var id: String { directory }

    /// Runs Claude Code on this profile's sign-in alone, whatever the shell has exported.
    public var launchCommand: String {
        let cleared = "env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL"
        return isDefault ? "\(cleared) -u CLAUDE_CONFIG_DIR claude"
            : "\(cleared) CLAUDE_CONFIG_DIR=\(ClaudeProfiles.shellQuoted(directory)) claude"
    }
}

public enum ClaudeProfileError: Error, Equatable {
    case invalidName, exists
}

public struct ClaudeProfiles: Sendable {
    /// Marks a folder made here, which has none of Claude Code's files until its first start.
    static let marker = ".thermo-profile"
    let home: URL
    /// Whether a Keychain item of that service exists; nil when unknown. Never reads the secret.
    let keychainHasItem: @Sendable (String) -> Bool?
    let alive: @Sendable (pid_t) -> Bool

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                keychainHasItem: @escaping @Sendable (String) -> Bool? = ClaudeProfiles.systemKeychainHasItem,
                alive: @escaping @Sendable (pid_t) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        self.home = home
        self.keychainHasItem = keychainHasItem
        self.alive = alive
    }

    public func list() -> [ClaudeProfile] {
        var profiles = [profile(name: "default", directory: home.appendingPathComponent(".claude"), isDefault: true)]
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        for entry in entries.sorted() where entry.hasPrefix(".claude-") {
            let directory = home.appendingPathComponent(entry)
            if isProfile(directory) {
                profiles.append(profile(name: String(entry.dropFirst(".claude-".count)), directory: directory, isDefault: false))
            }
        }
        return profiles
    }

    @discardableResult
    public func create(name: String) throws -> ClaudeProfile {
        guard Self.isValid(name: name) else { throw ClaudeProfileError.invalidName }
        let directory = home.appendingPathComponent(".claude-" + name)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw ClaudeProfileError.exists }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: directory.appendingPathComponent(Self.marker).path, contents: nil)
        return profile(name: name, directory: directory, isDefault: false)
    }

    public static func isValid(name: String) -> Bool {
        name.range(of: #"^[a-z0-9][a-z0-9_-]{0,30}$"#, options: .regularExpression) != nil
    }

    /// `~/.claude-code-router` and the like share the prefix, so a folder must show it is a profile.
    func isProfile(_ directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        return [Self.marker, ".claude.json", "projects"].contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    func profile(name: String, directory: URL, isDefault: Bool) -> ClaudeProfile {
        let config = isDefault ? home.appendingPathComponent(".claude.json") : directory.appendingPathComponent(".claude.json")
        let root = (try? Data(contentsOf: config)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let account = root?["oauthAccount"] as? [String: Any]
        let hasFile = FileManager.default.fileExists(atPath: directory.appendingPathComponent(".credentials.json").path)
        let signedIn: Bool? = hasFile ? true : keychainHasItem(Self.keychainService(directory: directory.path, isDefault: isDefault))
        let modified = (try? FileManager.default.attributesOfItem(atPath: config.path))?[.modificationDate] as? Date
        return ClaudeProfile(name: name, directory: directory.path, isDefault: isDefault,
                             email: account?["emailAddress"] as? String,
                             organization: account?["organizationName"] as? String,
                             billing: account?["billingType"] as? String,
                             signedIn: signedIn, liveSessions: liveSessions(directory), lastUsed: modified)
    }

    func liveSessions(_ directory: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("sessions").path)) ?? []
        return files.filter { $0.hasSuffix(".json") && pid_t($0.dropLast(5)).map(alive) == true }.count
    }

    /// Claude Code names the item after the first 8 hex digits of the folder's SHA-256.
    static func keychainService(directory: String, isDefault: Bool) -> String {
        let base = "Claude Code-credentials"
        if isDefault { return base }
        let digest = SHA256.hash(data: Data(directory.precomposedStringWithCanonicalMapping.utf8))
        return base + "-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `security` without `-w` prints attributes only, so macOS asks nothing and no secret leaves the Keychain.
    @Sendable public static func systemKeychainHasItem(_ service: String) -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0: return true
        case 44: return false // errSecItemNotFound
        default: return nil
        }
    }
}
