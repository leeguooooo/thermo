import Foundation

/// What a module tells the kernel about itself, read from `module.json` in the module's bundle
/// without starting the module: the sidebar, hotkeys, commands and permissions of a module that is
/// switched off or not running are all known from this file alone.
public struct ModuleManifest: Codable, Sendable, Equatable {
    /// Bumped when a manifest written for the old number can no longer be read correctly.
    public static let currentInterface = 1

    public enum Launch: String, Codable, Sendable {
        /// Started on first use, ended when idle.
        case onDemand
        /// Process started ahead of use so its UI appears at once (screenshot).
        case prewarm
        /// Runs whenever the module is on (background sampling).
        case always
    }

    public struct Entry: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case page, overviewCard, menuBarItem, hotkey, toolbarAction
            /// Rendered by the module in its own process and embedded by the kernel.
            public var showsUI: Bool { self == .page || self == .overviewCard || self == .menuBarItem }
        }
        public var id: String
        public var kind: Kind
        public var title: String
        public var symbol: String?
        /// The module's scene to embed, for kinds that show UI.
        public var scene: String?
        /// The command to run, for hotkeys and toolbar actions.
        public var command: String?

        public init(id: String, kind: Kind, title: String, symbol: String? = nil, scene: String? = nil, command: String? = nil) {
            self.id = id; self.kind = kind; self.title = title; self.symbol = symbol; self.scene = scene; self.command = command
        }
    }

    /// One operation of the module. The CLI subcommand and the MCP tool are generated from it.
    public struct Command: Codable, Sendable, Equatable {
        public struct Parameter: Codable, Sendable, Equatable {
            public enum Kind: String, Codable, Sendable { case string, integer, boolean, path }
            public var name: String
            public var kind: Kind
            public var required: Bool
            public var summary: String
            public init(name: String, kind: Kind, required: Bool = false, summary: String) {
                self.name = name; self.kind = kind; self.required = required; self.summary = summary
            }
        }
        public var id: String
        public var title: String
        public var summary: String
        /// Changes something on the Mac (as opposed to reading).
        public var mutates: Bool
        public var parameters: [Parameter]
        /// What running it may ask of the kernel; each must be covered by the module's capabilities.
        public var capabilities: [Capability]

        public init(id: String, title: String, summary: String, mutates: Bool = false, parameters: [Parameter] = [], capabilities: [Capability] = []) {
            self.id = id; self.title = title; self.summary = summary; self.mutates = mutates
            self.parameters = parameters; self.capabilities = capabilities
        }
    }

    public var interface: Int
    /// Reverse-DNS, lowercase: `dev.thermo.disk`.
    public var id: String
    public var name: String
    public var summary: String
    public var symbol: String
    public var version: String
    public var launch: Launch
    /// On for a new install. Existing installs keep what they had.
    public var enabledByDefault: Bool
    public var capabilities: [Capability]
    public var entries: [Entry]
    public var commands: [Command]
    /// Translations of the texts above, by language (`zh-Hans`, `ja`) and then by key: `name`,
    /// `summary`, `entry.<id>.title`, `command.<id>.title`, `command.<id>.summary`,
    /// `parameter.<command id>.<name>.summary`. The texts in the manifest itself are English.
    public var localizations: [String: [String: String]]?

    public init(interface: Int = ModuleManifest.currentInterface, id: String, name: String, summary: String, symbol: String, version: String,
                launch: Launch = .onDemand, enabledByDefault: Bool = false, capabilities: [Capability] = [], entries: [Entry] = [], commands: [Command] = [],
                localizations: [String: [String: String]]? = nil) {
        self.interface = interface; self.id = id; self.name = name; self.summary = summary; self.symbol = symbol; self.version = version
        self.launch = launch; self.enabledByDefault = enabledByDefault; self.capabilities = capabilities; self.entries = entries; self.commands = commands
        self.localizations = localizations
    }

    /// Every key a translation may use, for this manifest.
    var localizableKeys: Set<String> {
        var keys: Set<String> = ["name", "summary"]
        for entry in entries { keys.insert("entry.\(entry.id).title") }
        for command in commands {
            keys.insert("command.\(command.id).title"); keys.insert("command.\(command.id).summary")
            for parameter in command.parameters { keys.insert("parameter.\(command.id).\(parameter.name).summary") }
        }
        return keys
    }

    /// The manifest as shown in `language` (`zh-Hans`, falling back to `zh`); texts without a
    /// translation stay as written.
    public func localized(_ language: String) -> ModuleManifest {
        let base = language.split(separator: "-").first.map(String.init) ?? language
        guard let table = localizations?[language] ?? localizations?[base] else { return self }
        var copy = self
        copy.name = table["name"] ?? name
        copy.summary = table["summary"] ?? summary
        copy.entries = entries.map { entry in var e = entry; e.title = table["entry.\(entry.id).title"] ?? entry.title; return e }
        copy.commands = commands.map { command in
            var c = command
            c.title = table["command.\(command.id).title"] ?? command.title
            c.summary = table["command.\(command.id).summary"] ?? command.summary
            c.parameters = command.parameters.map { parameter in
                var p = parameter; p.summary = table["parameter.\(command.id).\(parameter.name).summary"] ?? parameter.summary; return p
            }
            return c
        }
        return copy
    }

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public var problems: [String]
        public var description: String { problems.joined(separator: "; ") }
    }

    /// Decodes and validates. A manifest with any problem is refused whole: the kernel never loads
    /// a module on a partly understood manifest.
    public static func load(_ data: Data) throws -> ModuleManifest {
        let manifest: ModuleManifest
        do { manifest = try JSONDecoder().decode(ModuleManifest.self, from: data) }
        catch { throw Invalid(problems: ["unreadable manifest: \(error)"]) }
        let problems = manifest.problems()
        if !problems.isEmpty { throw Invalid(problems: problems) }
        return manifest
    }

    static let identifier = try! NSRegularExpression(pattern: "^[a-z][a-z0-9-]*(\\.[a-z][a-z0-9-]*){2,}$")
    static let local = try! NSRegularExpression(pattern: "^[a-z][a-z0-9-]*$")
    static let semantic = try! NSRegularExpression(pattern: "^[0-9]+\\.[0-9]+\\.[0-9]+$")
    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Everything wrong with the manifest, in reading order; empty when it can be loaded.
    public func problems() -> [String] {
        var found: [String] = []
        if interface < 1 || interface > Self.currentInterface {
            found.append("interface \(interface) is not supported (this Thermo reads 1…\(Self.currentInterface))")
        }
        if !Self.matches(Self.identifier, id) { found.append("id \(id) must be lowercase reverse-DNS with at least three parts") }
        if name.isEmpty { found.append("name is empty") }
        if symbol.isEmpty { found.append("symbol is empty") }
        if !Self.matches(Self.semantic, version) { found.append("version \(version) must look like 1.2.3") }

        for capability in capabilities {
            if capability.kind.takesScope {
                guard let scope = capability.scope else { found.append("\(capability.kind.rawValue) needs a scope"); continue }
                if capability.kind == .networkConnect {
                    if scope == "*" || scope == "*." || scope.contains("/") { found.append("network scope \(scope) must be a host or *.domain") }
                } else if let path = Capability.path(scope, home: "/Users/x") {
                    // Deleting may never be granted for a whole volume or a whole home folder.
                    if capability.kind == .filesDelete, path == "/" || path == "/Users" || path == "/Users/x" {
                        found.append("files.delete may not cover \(scope)")
                    }
                } else { found.append("file scope \(scope) must be absolute or start with ~/ and may not contain ..") }
            } else if capability.scope != nil { found.append("\(capability.kind.rawValue) takes no scope") }
        }
        if Set(capabilities).count != capabilities.count { found.append("a capability is listed twice") }

        var commandIDs = Set<String>()
        for command in commands {
            if !Self.matches(Self.local, command.id) { found.append("command id \(command.id) must be lowercase letters, digits and hyphens") }
            if !commandIDs.insert(command.id).inserted { found.append("command \(command.id) is defined twice") }
            if command.summary.isEmpty { found.append("command \(command.id) has no summary") }
            if Set(command.parameters.map(\.name)).count != command.parameters.count { found.append("command \(command.id) repeats a parameter") }
            for needed in command.capabilities where !capabilities.contains(where: { $0.covers(needed, home: "/Users/x") }) {
                found.append("command \(command.id) uses \(needed), which the module does not declare")
            }
            // A command that deletes, ends processes or drives fans changes the Mac by definition.
            if !command.mutates, command.capabilities.contains(where: { $0.kind.alwaysConfirmed }) {
                found.append("command \(command.id) uses a confirmed capability and must be marked mutates")
            }
        }

        var entryIDs = Set<String>()
        for entry in entries {
            if !Self.matches(Self.local, entry.id) { found.append("entry id \(entry.id) must be lowercase letters, digits and hyphens") }
            if !entryIDs.insert(entry.id).inserted { found.append("entry \(entry.id) is defined twice") }
            if entry.title.isEmpty { found.append("entry \(entry.id) has no title") }
            if entry.kind.showsUI {
                if (entry.scene ?? "").isEmpty { found.append("entry \(entry.id) shows UI and needs a scene") }
            } else if let command = entry.command, commandIDs.contains(command) {
                if entry.scene != nil { found.append("entry \(entry.id) runs a command and takes no scene") }
            } else {
                found.append("entry \(entry.id) must name one of the module's commands")
            }
        }
        // A misspelt key would silently leave the English text in place.
        let known = localizableKeys
        for (language, table) in (localizations ?? [:]).sorted(by: { $0.key < $1.key }) {
            if language.isEmpty || language == "en" { found.append("localizations may not redefine the English texts (\(language.isEmpty ? "empty language" : language))") }
            for (key, text) in table.sorted(by: { $0.key < $1.key }) {
                if !known.contains(key) { found.append("localization \(language) has unknown key \(key)") }
                if text.isEmpty { found.append("localization \(language) leaves \(key) empty") }
            }
        }
        return found
    }
}
