import Foundation

/// "Which features are on and how they are set up", as a file someone else can import.
///
/// Only an allow-list leaves the Mac: the built-in feature switches and settings that hold a choice,
/// never a path, an account, a consent, a token or history. Import reads the same list back and
/// ignores everything else, so a hand-edited file can't write arbitrary preferences.
public enum SetupShare {
    public static let format = "dev.thermo.setup"
    public static let version = 1

    public enum Value: Codable, Equatable, Sendable {
        case bool(Bool), int(Int), double(Double), string(String), data(Data)
    }
    enum Kind { case bool, int, double, choice, shortcut }

    /// Settings that describe a choice and take effect from the stored value alone. Strings must be short
    /// identifiers. Left out on purpose: settings applied through a flow of their own (charge limit and lid
    /// guard go through the helper, menu bar management asks for Accessibility, global shortcuts have to be
    /// registered and may replace Spotlight's), and anything holding a path, account, consent or history.
    static let settings: [String: Kind] = [
        "alertsEnabled": .bool,
        "titleMetric": .choice, "menuLayout": .choice, "menuPresentation": .choice, "menuPrimary": .choice,
        "menuSecondary": .choice, "menuLeftClick": .choice, "menuRightClick": .choice,
        "computePage.sort": .choice, "apps.sort": .choice, "sensors.hottestFirst": .bool,
        "menuBarAutoCollapseSeconds": .double,
        "focus.focusMinutes": .int, "focus.shortBreakMinutes": .int, "focus.longBreakMinutes": .int,
        "focus.longBreakEvery": .int, "focus.autoStartFocusAfterBreak": .bool, "focus.showProgressIcon": .bool,
        "focus.startOnLaunch": .bool,
        "dev.thermo.search.switchToASCIIInput": .bool, "dev.thermo.cleanScreen.duration": .double,
        "module.discovery.recommendations.enabled": .bool,
    ]

    public struct Document: Codable, Equatable, Sendable {
        public var format: String
        public var version: Int
        public var modules: [String: Bool]
        public var settings: [String: Value]
        public init(modules: [String: Bool], settings: [String: Value]) {
            format = SetupShare.format; version = SetupShare.version; self.modules = modules; self.settings = settings
        }
    }

    static func accepted(_ key: String, _ value: Value) -> Bool {
        switch (settings[key], value) {
        case (.bool?, .bool), (.int?, .int), (.double?, .double): return true
        case (.int?, .double(let d)): return d == d.rounded()
        case (.double?, .int): return true
        case (.choice?, .string(let s)):
            return s.count <= 64 && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._:-".unicodeScalars.contains($0) }
        case (.shortcut?, .data(let d)): return d.count <= 512
        default: return false
        }
    }

    static func read(_ key: String, _ defaults: UserDefaults) -> Value? {
        guard let kind = settings[key], let object = defaults.object(forKey: key) else { return nil }
        let value: Value?
        switch kind {
        case .bool: value = (object as? NSNumber).map { .bool($0.boolValue) }
        case .int: value = (object as? NSNumber).map { .int($0.intValue) }
        case .double: value = (object as? NSNumber).map { .double($0.doubleValue) }
        case .choice: value = (object as? String).map { .string($0) }
        case .shortcut: value = (object as? Data).map { .data($0) }
        }
        return value.flatMap { accepted(key, $0) ? $0 : nil }
    }

    /// The setup of `manifests` (the built-in features) as stored in `defaults`.
    public static func export(_ manifests: [ModuleManifest], from defaults: UserDefaults) -> Document {
        var modules: [String: Bool] = [:]
        for manifest in manifests { modules[manifest.id] = ModulePreferences.isEnabled(manifest, in: defaults) }
        var values: [String: Value] = [:]
        for key in settings.keys { if let value = read(key, defaults) { values[key] = value } }
        return Document(modules: modules, settings: values)
    }

    public static func encode(_ document: Document) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    public enum ReadError: Error, Equatable { case notASetupFile, newerVersion(Int), tooLarge }

    /// What importing would change, decided before anything is written.
    public struct Review: Equatable, Sendable {
        public var switchOn: [String]
        public var switchOff: [String]
        public var settings: [String: Value]
        /// Entries the file carries that this version does not import (unknown features, keys or values).
        public var ignored: [String]
        public var isEmpty: Bool { switchOn.isEmpty && switchOff.isEmpty && settings.isEmpty }
    }

    public static func review(_ data: Data, manifests: [ModuleManifest], current defaults: UserDefaults) throws -> Review {
        guard data.count <= 256 * 1024 else { throw ReadError.tooLarge }
        guard let document = try? JSONDecoder().decode(Document.self, from: data), document.format == format else { throw ReadError.notASetupFile }
        guard document.version <= version else { throw ReadError.newerVersion(document.version) }
        let known = Dictionary(uniqueKeysWithValues: manifests.map { ($0.id, $0) })
        var review = Review(switchOn: [], switchOff: [], settings: [:], ignored: [])
        for (id, on) in document.modules.sorted(by: { $0.key < $1.key }) {
            guard let manifest = known[id] else { review.ignored.append(id); continue }
            if ModulePreferences.isEnabled(manifest, in: defaults) != on { on ? review.switchOn.append(id) : review.switchOff.append(id) }
        }
        for (key, value) in document.settings.sorted(by: { $0.key < $1.key }) {
            guard accepted(key, value) else { review.ignored.append(key); continue }
            if read(key, defaults) != value { review.settings[key] = value }
        }
        return review
    }

    /// Writes the reviewed settings. Feature switches are left to the caller, which has to stop
    /// or start each feature properly rather than only flip its preference.
    public static func applySettings(_ review: Review, to defaults: UserDefaults) {
        for (key, value) in review.settings where accepted(key, value) {
            switch value {
            case .bool(let b): defaults.set(b, forKey: key)
            case .int(let i): defaults.set(i, forKey: key)
            case .double(let d): settings[key] == .int ? defaults.set(Int(d), forKey: key) : defaults.set(d, forKey: key)
            case .string(let s): defaults.set(s, forKey: key)
            case .data(let d): defaults.set(d, forKey: key)
            }
        }
    }
}
