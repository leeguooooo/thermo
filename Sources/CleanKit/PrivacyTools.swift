import Foundation
import Darwin
import CryptoKit
import ThermoL10n

/// User-level privacy controls. Never invoked by the privileged Thermo helper.
public struct PrivacyBrowserProfile: Identifiable, Sendable {
    public let browser: String
    public let directory: URL
    public let firefox: Bool
    public var id: String { directory.path }
    public var name: String { "\(browser) · \(directory.lastPathComponent)" }
}

public enum PrivacyBrowserControl: Sendable { case location, webRTC }
public struct PrivacyExitLocation: Sendable {
    public let country: String
    public let timezone: String
}
public struct PrivacyCommandResult: Sendable {
    public let status: Int32
    public let output: String
    public init(status: Int32, output: String = "") { self.status = status; self.output = output }
}
public struct PrivacyToolsService: @unchecked Sendable {
    public typealias Runner = @Sendable (String, [String]) throws -> PrivacyCommandResult
    public let home: URL
    private let run: Runner
    private let fm = FileManager.default
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, runner: @escaping Runner = { try PrivacyToolsService.command($0, $1) }) {
        // Foundation resolvingSymlinksInPath may retain the /var alias while directory
        // enumeration returns /private/var. POSIX realpath keeps a consistent physical root.
        if let resolved = realpath(home.path, nil) {
            self.home = URL(fileURLWithPath: String(cString: resolved)); free(resolved)
        } else { self.home = URL(fileURLWithPath: Self.lexicalPath(home.path)) }
        self.run = runner
    }
    private var storage: URL { home.appendingPathComponent("Library/Application Support/Thermo/PrivacyBackups") }
    private struct FileChange: Codable {
        var path: String; var before: Data?; var afterHash: String
    }
    private struct Snapshot: Codable { var created: Date; var files: [FileChange] }
    private func failure(_ message: String) -> NSError { NSError(domain: "ThermoPrivacy", code: 1, userInfo: [NSLocalizedDescriptionKey: tr(message)]) }
    public static func command(_ executable: String, _ arguments: [String]) throws -> PrivacyCommandResult {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        // Drain before wait: sqlite and diagnostic output must not fill the pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return .init(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
    private func checked(_ executable: String, _ arguments: [String]) throws -> String {
        let result = try run(executable, arguments)
        guard result.status == 0 else { throw failure(tr("Command failed (%1$@, exit %2$@).", URL(fileURLWithPath: executable).lastPathComponent, String(result.status))) }
        return result.output
    }
    /// Reject symlinks in every existing component, including the profile root and backup directory.
    private static func lexicalPath(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }
    private func safe(_ url: URL) throws {
        // standardizedFileURL can rewrite physical /private/var paths to /var on macOS.
        // Normalize dot components lexically so a /var alias does not defeat symlink checks.
        let path = Self.lexicalPath(url.path)
        guard path.hasPrefix(home.path + "/") else { throw failure("Path outside the home directory.") }
        let homeAttributes = try fm.attributesOfItem(atPath: home.path)
        guard (homeAttributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(), homeAttributes[.type] as? FileAttributeType == .typeDirectory else { throw failure("Home directory ownership is unsupported.") }
        var cursor = home
        let parts = path.dropFirst(home.path.count + 1).split(separator: "/")
        for (index, component) in parts.enumerated() {
            cursor.appendPathComponent(String(component))
            if fm.fileExists(atPath: cursor.path) || (try? fm.destinationOfSymbolicLink(atPath: cursor.path)) != nil {
                let attributes = try fm.attributesOfItem(atPath: cursor.path)
                let type = attributes[.type] as? FileAttributeType
                guard type == .typeDirectory || (index == parts.count - 1 && type == .typeRegular),
                      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                    throw failure("Path must contain only files and directories owned by the current user; symbolic links are unsupported.")
                }
            }
        }
    }
    private func read(_ url: URL) throws -> Data {
        try safe(url)
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 32 * 1024 * 1024 else { throw failure("Settings or backup file is unsupported or exceeds 32 MB.") }
        return try Data(contentsOf: url)
    }
    private func prepareStorage() throws {
        try safe(storage)
        try fm.createDirectory(at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storage.path)
    }
    private func write(_ data: Data, to url: URL) throws {
        try safe(url); try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func fileHash(_ url: URL) throws -> String {
        try safe(url)
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256()
        while let block = try file.read(upToCount: 1024 * 1024), !block.isEmpty { digest.update(data: block) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public func discoverProfiles() throws -> [PrivacyBrowserProfile] {
        var profiles: [PrivacyBrowserProfile] = []
        let roots = [("Chrome", "Google/Chrome"), ("Edge", "Microsoft Edge"), ("Brave", "BraveSoftware/Brave-Browser"), ("Firefox", "Firefox/Profiles")]
        for (browser, suffix) in roots {
            let root = home.appendingPathComponent("Library/Application Support/" + suffix)
            try safe(root)
            guard fm.fileExists(atPath: root.path) else { continue }
            for child in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
                let firefox = browser == "Firefox"
                // Chromium root also contains singleton/version symlinks unrelated to profiles.
                // Filter names before safety checks so those do not block genuine profiles.
                guard firefox || child.lastPathComponent == "Default" || child.lastPathComponent.hasPrefix("Profile ") else { continue }
                let attributes = try fm.attributesOfItem(atPath: child.path)
                if firefox, attributes[.type] as? FileAttributeType == .typeRegular { continue }
                try safe(child)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
                let marker = child.appendingPathComponent(firefox ? "prefs.js" : "Preferences")
                try safe(marker)
                if fm.fileExists(atPath: marker.path) { profiles.append(.init(browser: browser, directory: child, firefox: firefox)) }
            }
        }
        return profiles.sorted { $0.name < $1.name }
    }
    public func requireBrowsersClosed() throws {
        let output = try checked("/bin/ps", ["-axo", "comm="])
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw failure("Cannot verify running browsers; no changes were made.") }
        let names = ["google chrome", "microsoft edge", "brave browser", "firefox", "firefox-bin", "chrome", "chromium", "chromium-browser", "msedge", "brave"]
        let running = output.split(separator: "\n").map { URL(fileURLWithPath: String($0).trimmingCharacters(in: .whitespaces)).lastPathComponent.lowercased() }
        guard !running.contains(where: { value in names.contains(value) || value.hasPrefix("google chrome helper") || value.hasPrefix("microsoft edge helper") || value.hasPrefix("brave browser helper") }) else { throw failure("Quit Chrome, Edge, Brave and Firefox completely, then try again. Thermo will not close your browsers.") }
        for suffix in ["Google/Chrome", "Microsoft Edge", "BraveSoftware/Brave-Browser"] {
            let lock = home.appendingPathComponent("Library/Application Support/" + suffix + "/SingletonLock")
            if let target = try? fm.destinationOfSymbolicLink(atPath: lock.path) {
                let pidText = target.split(separator: "-").last.map(String.init) ?? ""
                guard let pid = Int32(pidText), pid > 0, kill(pid, 0) != 0, errno == ESRCH else { throw failure("Browser profile lock is active or cannot be verified. Quit browsers before continuing.") }
            } else if fm.fileExists(atPath: lock.path) { throw failure("Browser profile lock is active or cannot be verified. Quit browsers before continuing.") }
        }
    }
    public func applyBrowser(_ control: PrivacyBrowserControl) throws -> String {
        try requireBrowsersClosed()
        let profiles = try discoverProfiles()
        guard !profiles.isEmpty else { throw failure("No supported browser profiles found.") }
        var planned: [(URL, Data?, Data)] = []
        for profile in profiles {
            if profile.firefox {
                for name in ["prefs.js", "user.js"] {
                    let file = profile.directory.appendingPathComponent(name); try safe(file)
                    let original = fm.fileExists(atPath: file.path) ? try read(file) : nil
                    guard let old = String(data: original ?? Data(), encoding: .utf8) else { throw failure("Unsupported Firefox preference encoding.") }
                    let key = control == .location ? "geo.enabled" : "media.peerconnection.enabled"
                    let escaped = NSRegularExpression.escapedPattern(for: key)
                    let pattern = "(?m)^\\s*user_pref\\(\\s*\"" + escaped + "\"\\s*,[^\\n]*\\);[^\\n]*\\n?"
                    let cleaned = old.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
                    planned.append((file, original, Data((cleaned + "\nuser_pref(\"\(key)\", false);\n").utf8)))
                    guard planned.reduce(0, { $0 + ($1.1?.count ?? 0) + $1.2.count }) <= 24 * 1024 * 1024 else { throw failure("Browser settings batch exceeds the safe backup size limit.") }
                }
            } else {
                let file = profile.directory.appendingPathComponent("Preferences"); try safe(file)
                let original = try read(file)
                guard var object = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw failure("Unsupported browser Preferences format.") }
                if control == .location {
                    var profile = object["profile"] as? [String: Any] ?? [:]
                    var values = profile["default_content_setting_values"] as? [String: Any] ?? [:]
                    values["geolocation"] = 2; profile["default_content_setting_values"] = values; object["profile"] = profile
                } else {
                    var values = object["webrtc"] as? [String: Any] ?? [:]
                    values["ip_handling_policy"] = "disable_non_proxied_udp"; object["webrtc"] = values
                }
                planned.append((file, original, try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])))
                guard planned.reduce(0, { $0 + ($1.1?.count ?? 0) + $1.2.count }) <= 24 * 1024 * 1024 else { throw failure("Browser settings batch exceeds the safe backup size limit.") }
            }
        }
        try prepareStorage()
        let entries = planned.map { file, original, data -> FileChange in
            .init(path: file.path, before: original, afterHash: hash(data))
        }
        let snapshotURL = storage.appendingPathComponent("browser-\(Date().timeIntervalSince1970)-\(UUID().uuidString).json")
        // Persist rollback data before the first change. Partial operations remain restorable.
        try write(JSONEncoder().encode(Snapshot(created: Date(), files: entries)), to: snapshotURL)
        for (file, original, data) in planned {
            try requireBrowsersClosed()
            let current = fm.fileExists(atPath: file.path) ? try read(file) : nil
            guard current == original else { throw failure("Browser settings changed during review. Stopped without overwriting this file; restore any earlier changes from backup.") }
            try write(data, to: file)
            guard try Data(contentsOf: file) == data else { throw failure("Browser settings read-back failed. Use Restore last browser change.") }
        }
        return tr("Updated %1$@ profiles. Restart browsers to apply. Backups: %2$@", String(profiles.count), storage.path)
    }
    public func restoreLatestBrowserChange() throws -> String {
        try requireBrowsersClosed(); try safe(storage)
        let files = (try? fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? []
        guard let latest = files.filter({ $0.lastPathComponent.hasPrefix("browser-") }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first else { throw failure("No browser backup found.") }
        try safe(latest)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: read(latest))
        let allowed = Set(try discoverProfiles().flatMap { profile in
            (profile.firefox ? ["prefs.js", "user.js"] : ["Preferences"]).map { profile.directory.appendingPathComponent($0).path }
        })
        guard !snapshot.files.isEmpty, Set(snapshot.files.map(\.path)).count == snapshot.files.count,
              snapshot.files.allSatisfy({ allowed.contains($0.path) }) else { throw failure("Backup contains unsupported or duplicate browser paths.") }
        for entry in snapshot.files {
            let file = URL(fileURLWithPath: entry.path); try safe(file)
            let current = fm.fileExists(atPath: file.path) ? try read(file) : nil
            // A partial write may still contain the original file. Never overwrite later external changes.
            guard current.map(hash) == entry.afterHash || current == entry.before else { throw failure(tr("Browser settings changed after backup. Automatic restore stopped to protect newer changes: %1$@", file.path)) }
        }
        for entry in snapshot.files {
            try requireBrowsersClosed()
            let file = URL(fileURLWithPath: entry.path)
            let current = fm.fileExists(atPath: file.path) ? try read(file) : nil
            guard current.map(hash) == entry.afterHash || current == entry.before else { throw failure("Browser settings changed during restore. Stopped to protect newer changes.") }
            if let before = entry.before { try write(before, to: file) }
            else if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        }
        try fm.removeItem(at: latest)
        return tr("Restored the previous browser settings. Restart browsers to apply.")
    }
    public static let mailCookiePredicate = "lower(%@) = 'mail.com' OR lower(%@) LIKE '%%.mail.com'"
    public func clearMailCookies() throws -> String {
        try requireBrowsersClosed(); try prepareStorage()
        var count = 0
        var errors: [String] = []
        let profiles = try discoverProfiles()
        guard !profiles.isEmpty else { throw failure("No supported browser profiles found.") }
        for profile in profiles {
            for name in profile.firefox ? ["cookies.sqlite"] : ["Network/Cookies", "Cookies"] {
                do {
                let database = profile.directory.appendingPathComponent(name); try safe(database)
                guard fm.fileExists(atPath: database.path) else { continue }
                for suffix in ["-wal", "-shm", "-journal"] { try safe(URL(fileURLWithPath: database.path + suffix)) }
                let table = profile.firefox ? "moz_cookies" : "cookies"
                let column = profile.firefox ? "host" : "host_key"
                let triggerCount = try checked("/usr/bin/sqlite3", [database.path, "SELECT count(*) FROM sqlite_schema WHERE type='trigger';"]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard triggerCount == "0" else { throw failure("Cookie database has triggers; stopped without deleting cookies.") }
                let backup = storage.appendingPathComponent("cookies-\(UUID().uuidString).sqlite")
                let quotedBackup = backup.path.replacingOccurrences(of: "'", with: "''")
                _ = try checked("/usr/bin/sqlite3", [database.path, "VACUUM INTO '\(quotedBackup)';"])
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                let manifest: [String: String] = ["sourceDatabase": database.path, "browser": profile.browser, "profile": profile.directory.path, "created": ISO8601DateFormatter().string(from: Date()), "backupSHA256": try fileHash(backup), "backupFile": backup.lastPathComponent]
                try write(JSONEncoder().encode(manifest), to: backup.appendingPathExtension("json"))
                try requireBrowsersClosed()
                let predicate = String(format: Self.mailCookiePredicate, column, column)
                let result = try checked("/usr/bin/sqlite3", ["-bail", database.path, "PRAGMA busy_timeout=1500; PRAGMA trusted_schema=OFF; PRAGMA secure_delete=ON; BEGIN IMMEDIATE; DELETE FROM \(table) WHERE \(predicate); COMMIT; SELECT 'thermo_deleted=' || changes();"])
                guard let tagged = result.split(separator: "\n").first(where: { $0.hasPrefix("thermo_deleted=") }),
                      let deleted = Int(tagged.dropFirst("thermo_deleted=".count)), deleted >= 0 else { throw failure("Cookie deletion completed, but the deletion count could not be verified. Inspect the database before retrying.") }
                count += deleted
                // The transaction is already committed. A checkpoint failure must not hide its outcome.
                do { _ = try checked("/usr/bin/sqlite3", ["-bail", database.path, "PRAGMA wal_checkpoint(TRUNCATE);"]) }
                catch { errors.append(profile.name + ": " + tr("Cookie deletion committed, but the WAL checkpoint failed. Keep the database and its WAL files together.")) }
                } catch { errors.append(profile.name + ": " + error.localizedDescription) }
            }
        }
        let summary = tr("Deleted %1$@ mail.com cookies. Cookie backups contain login data; keep them private: %2$@. Cookie restore is manual and requires closed browsers.", String(count), storage.path)
        return errors.isEmpty ? summary : summary + "\n" + tr("Some profiles failed: %1$@", errors.joined(separator: "\n"))
    }
    public func clearClaudeEnvironment() throws -> String {
        let names = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"]
        var succeeded: [String] = []
        var failed: [String] = []
        for name in names {
            do { _ = try checked("/bin/launchctl", ["unsetenv", name]); succeeded.append(name) }
            catch { failed.append(name) }
        }
        let summary = tr("Removed %1$@ Claude variable names from the user launchd environment. Restart apps to apply. Shell files and existing processes are unchanged. Values were not read or backed up.", String(succeeded.count))
        return summary + "\n" + tr("Successful variable names: %1$@", succeeded.joined(separator: ", ")) + (failed.isEmpty ? "" : "\n" + tr("Failed variable names: %1$@", failed.joined(separator: ", ")))

    }
    private func authorize(_ script: String) throws {
        // Scripts are fixed strings except timezone, which is restricted to validated IANA identifiers.
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        _ = try checked("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
    }
    public func flushDNS() throws -> String {
        try authorize("/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder")
        return tr("DNS cache flush requested successfully. DNS servers and proxy settings were unchanged.")
    }
    public static func validTimezone(_ value: String) -> Bool {
        !value.isEmpty && value.count < 81 && value.range(of: "^[A-Za-z0-9_+/-]+$", options: .regularExpression) != nil && TimeZone.knownTimeZoneIdentifiers.contains(value)
    }
    public func lookupExitLocation() async throws -> PrivacyExitLocation {
        var request = URLRequest(url: URL(string: "https://ipwho.is/")!); request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 65536,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["success"] as? Bool != false,
              let tz = (object["timezone"] as? [String: Any])?["id"] as? String, Self.validTimezone(tz),
              let country = object["country_code"] as? String, country.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else { throw failure("Exit location lookup failed. No settings changed.") }
        return .init(country: country, timezone: tz)
    }
    public func setTimezone(_ timezone: String) throws -> String {
        guard Self.validTimezone(timezone) else { throw failure("Invalid timezone.") }
        try prepareStorage()
        let previous = try fm.destinationOfSymbolicLink(atPath: "/etc/localtime")
        let marker = "/zoneinfo/"
        guard let range = previous.range(of: marker), Self.validTimezone(String(previous[range.upperBound...])) else { throw failure("Cannot determine previous timezone safely.") }
        let prior = String(previous[range.upperBound...])
        let backup = storage.appendingPathComponent("timezone.json")
        if !fm.fileExists(atPath: backup.path) { try write(JSONEncoder().encode(["previous": prior]), to: backup) }
        try authorize("/usr/sbin/systemsetup -settimezone '\(timezone)'")
        guard try fm.destinationOfSymbolicLink(atPath: "/etc/localtime").hasSuffix("/" + timezone) else { throw failure("Timezone read-back failed.") }
        return tr("System timezone: %1$@. Automatic timezone may override it. Country, language and browser-only proxies are unchanged.", timezone)
    }
    public func restoreTimezone() throws -> String {
        let backup = storage.appendingPathComponent("timezone.json"); try safe(backup)
        let value = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: backup))
        guard let previous = value["previous"] else { throw failure("No previous timezone backup found.") }
        let result = try setTimezone(previous); try fm.removeItem(at: backup); return result
    }
}
