import Foundation

/// Remote catalogs are untrusted: every field is checked here, before any page or command sees it.
public enum StoreText {
    /// One line of plain text: control and invisible format characters removed, length capped.
    public static func clean(_ value: Any?, limit: Int) -> String? {
        guard let text = value as? String else { return nil }
        let scalars = text.unicodeScalars.map { scalar -> Unicode.Scalar in
            CharacterSet.newlines.contains(scalar) || scalar == "\t" ? " " : scalar
        }.filter { !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars)
        let trimmed = String(out).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(limit))
    }

    /// Only an `https://host/…` URL without credentials survives; anything else is no link at all.
    public static func httpsURL(_ value: Any?) -> URL? {
        guard let raw = value as? String, !raw.isEmpty, raw.count <= 2048,
              raw.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value != 0x7F && $0 != "\\" }),
              let parts = URLComponents(string: raw), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }

    /// Names reach a command line: a leading dash could otherwise read as an option.
    public static func token(_ value: Any?, limit: Int = 64) -> String? {
        guard let text = value as? String, !text.isEmpty, text.count <= limit,
              let first = text.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic || ("0"..."9").contains(Character(first)),
              text.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0)) || ".-_".unicodeScalars.contains($0)) })
        else { return nil }
        return text
    }

    /// A single emoji; catalogs cannot put text or a link in the icon slot.
    public static func emoji(_ value: Any?) -> String? {
        guard let text = value as? String, text.count == 1,
              text.unicodeScalars.contains(where: { $0.value > 0xFF && $0.properties.isEmoji }) else { return nil }
        return text
    }
}

public enum StoreVersion {
    /// True only when both are dotted numbers and `latest` is higher. Unknown formats never claim an update.
    public static func isNewer(_ latest: String?, than current: String?) -> Bool {
        guard let a = parts(latest), let b = parts(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func parts(_ value: String?) -> [Int]? {
        guard var text = value, !text.isEmpty else { return nil }
        if text.hasPrefix("v") { text.removeFirst() }
        let numbers = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        return numbers.contains(nil) ? nil : numbers.compactMap { $0 }
    }
}

// MARK: - Marketplace

public struct MarketplacePlugin: Equatable, Sendable, Identifiable {
    public var name: String
    public var description: String?
    public var version: String?
    public var category: String?
    public var homepage: URL?
    public init(name: String, description: String? = nil, version: String? = nil, category: String? = nil, homepage: URL? = nil) {
        self.name = name; self.description = description; self.version = version; self.category = category; self.homepage = homepage
    }
    public var id: String { name }
    public var installID: String { name + "@" + Marketplace.name }
}

public struct Marketplace: Equatable, Sendable {
    public static let name = "leeguooooo-plugins"
    public static let source = "leeguooooo/plugins"
    public static let url = URL(string: "https://raw.githubusercontent.com/leeguooooo/plugins/main/.claude-plugin/marketplace.json")!
    public var plugins: [MarketplacePlugin]

    /// Nil unless this is the expected marketplace with at least one usable plugin.
    public static func decode(_ data: Data) -> Marketplace? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["name"] as? String == name, let rows = root["plugins"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        let plugins = rows.compactMap { row -> MarketplacePlugin? in
            guard let name = StoreText.token(row["name"]), seen.insert(name).inserted else { return nil }
            return MarketplacePlugin(name: name, description: StoreText.clean(row["description"], limit: 600),
                                     version: StoreText.clean(row["version"], limit: 32),
                                     category: StoreText.clean(row["category"], limit: 40),
                                     homepage: StoreText.httpsURL(row["homepage"]))
        }
        return plugins.isEmpty ? nil : Marketplace(plugins: plugins)
    }
}

// MARK: - What the use manager reports

public struct UseManagerState: Equatable, Sendable {
    /// Family CLI name → installed version (`use status --json`).
    public var cliVersions: [String: String] = [:]
    /// Name → newer version (`use update --check --json`, which exits non-zero when anything needs attention).
    public var updates: [String: String] = [:]
    /// Everything `use update NAME` is known to accept.
    public var managed: Set<String> = ["use-family"]

    public init() {}

    public mutating func read(status data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clis = root["clis"] as? [[String: Any]] else { return }
        for row in clis {
            guard let name = StoreText.token(row["name"]) else { continue }
            managed.insert(name)
            if let version = StoreText.clean(row["version"], limit: 32) { cliVersions[name] = version }
        }
    }

    public mutating func read(check data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return }
        updates = [:]
        for item in items where item["channel"] as? String == "cli" {
            guard let name = StoreText.token(item["name"]) else { continue }
            managed.insert(name)
            if item["status"] as? String == "available", let target = StoreText.clean(item["target"], limit: 32) { updates[name] = target }
        }
    }
}

// MARK: - State

public enum PluginState: Equatable, Sendable {
    case notInstalled, installed, updateAvailable(String)
}

public struct PluginRecord: Equatable, Sendable, Identifiable {
    public var plugin: MarketplacePlugin
    /// The Claude Code install actions apply to; user scope wins over a project install.
    public var install: InstalledPlugin?
    public var cliVersion: String?
    public var state: PluginState
    public var id: String { plugin.name }
    public var installedVersion: String? { install?.version ?? cliVersion }
}

public enum PluginRecords {
    public static func build(_ marketplace: Marketplace, installed: [InstalledPlugin], use: UseManagerState) -> [PluginRecord] {
        marketplace.plugins.map { plugin in
            let rows = installed.filter { $0.id == plugin.installID }
            let install = rows.first { $0.scope == "user" } ?? rows.first
            let cli = use.cliVersions[plugin.name]
            let state: PluginState
            if let install, StoreVersion.isNewer(plugin.version, than: install.version), let latest = plugin.version {
                state = .updateAvailable(latest)
            } else if let target = use.updates[plugin.name], install != nil || cli != nil {
                state = .updateAvailable(target)
            } else {
                state = install != nil || cli != nil ? .installed : .notInstalled
            }
            return PluginRecord(plugin: plugin, install: install, cliVersion: cli, state: state)
        }
    }
}

// MARK: - Commands

/// One program run. Arguments stay an array; nothing here ever passes through a shell.
public struct StoreCommand: Equatable, Sendable {
    public enum Tool: Equatable, Sendable { case claude, use, path(String) }
    public var tool: Tool
    public var arguments: [String]
    public var directory: String?
    public init(_ tool: Tool, _ arguments: [String], directory: String? = nil) {
        self.tool = tool; self.arguments = arguments; self.directory = directory
    }
}

public enum PluginCommands {
    public static let useInstallerURL = "https://raw.githubusercontent.com/leeguooooo/plugins/main/install-use.sh"
    /// What the page shows and the confirm button performs, in two steps without a pipe.
    public static let useInstallerDisplay = "curl -fsSL \(useInstallerURL) | sh"

    public static func install(_ plugin: MarketplacePlugin, marketplaceKnown: Bool) -> [StoreCommand] {
        (marketplaceKnown ? [] : [StoreCommand(.claude, ["plugin", "marketplace", "add", Marketplace.source])])
            + [StoreCommand(.claude, ["plugin", "install", plugin.installID, "--scope", "user"])]
    }

    /// The manager when it owns this name, else Claude Code; nil when neither can do it.
    public static func update(_ record: PluginRecord, use: UseManagerState?) -> [StoreCommand]? {
        if let use, use.managed.contains(record.plugin.name) {
            return [StoreCommand(.use, ["update", record.plugin.name, "--json"])]
        }
        guard let scoped = scoped(record) else { return nil }
        return [StoreCommand(.claude, ["plugin", "marketplace", "update", Marketplace.name]),
                StoreCommand(.claude, ["plugin", "update", record.plugin.installID] + scoped.arguments, directory: scoped.directory)]
    }

    public static func uninstall(_ record: PluginRecord) -> [StoreCommand]? {
        guard let scoped = scoped(record) else { return nil }
        return [StoreCommand(.claude, ["plugin", "uninstall", record.plugin.installID] + scoped.arguments, directory: scoped.directory)]
    }

    public static func downloadUseInstaller(to path: String) -> StoreCommand {
        StoreCommand(.path("/usr/bin/curl"), ["-fsSL", useInstallerURL, "-o", path])
    }

    public static func runUseInstaller(at path: String) -> StoreCommand {
        StoreCommand(.path("/bin/sh"), [path])
    }

    private static func scoped(_ record: PluginRecord) -> (arguments: [String], directory: String?)? {
        guard let install = record.install else { return nil }
        guard install.scope != "user" else { return (["--scope", "user"], nil) }
        guard let project = install.projectPath, FileManager.default.fileExists(atPath: project) else { return nil }
        return (["--scope", install.scope], project)
    }
}

extension ClaudePlugins {
    public static func marketplaceKnown(_ home: AgentHome = AgentHome()) -> Bool {
        guard let data = FileManager.default.contents(atPath: home.claudePlugins + "/known_marketplaces.json"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return root[Marketplace.name] != nil
    }
}

// MARK: - App store

public struct StoreApp: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var descriptionZH: String?
    public var descriptionEN: String?
    public var category: String?
    public var icon: String?
    public var url: URL
    public var bundleID: String?
}

public enum AppStoreCatalog {
    public static let url = URL(string: "https://app.leeguoo.com/app-store.json")!

    /// Rows without an https link are dropped; nil when nothing usable remains (an HTML page, say).
    public static func decode(_ data: Data) -> [StoreApp]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["apps"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        let apps = rows.compactMap { row -> StoreApp? in
            guard let id = StoreText.token(row["id"]), let title = StoreText.clean(row["title"], limit: 80),
                  let url = StoreText.httpsURL(row["url"]), seen.insert(id).inserted else { return nil }
            let text = row["description"] as? [String: Any]
            return StoreApp(id: id, title: title, descriptionZH: StoreText.clean(text?["zh"], limit: 400),
                            descriptionEN: StoreText.clean(text?["en"], limit: 400),
                            category: StoreText.clean(row["category"], limit: 40), icon: StoreText.emoji(row["icon"]),
                            url: url, bundleID: StoreText.token(row["bundle_id"], limit: 128))
        }
        return apps.isEmpty ? nil : apps
    }
}

// MARK: - Last good copy

public struct StoreCache: Sendable {
    public var directory: URL
    public init(home: String = NSHomeDirectory()) {
        directory = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Thermo/Store", isDirectory: true)
    }
    public init(directory: URL) { self.directory = directory }

    public func read(_ name: String) -> Data? { try? Data(contentsOf: directory.appendingPathComponent(name)) }

    /// Call only after the data decoded, so a bad response never replaces the last good copy.
    public func write(_ data: Data, as name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
