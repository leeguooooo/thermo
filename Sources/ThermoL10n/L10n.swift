import Foundation

/// UI languages. The English string is the key; other languages are tables keyed by it.
/// Tables live in code (not .lproj resources) because the CLI ships as a single binary and the app
/// bundle is assembled by scripts/build.sh, neither of which carries SwiftPM resource bundles.
public enum Language: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }

    /// The language's own name, for a picker.
    public var displayName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    var table: [String: String]? {
        switch self {
        case .english: return nil
        case .simplifiedChinese: return zhHans
        }
    }
}

public enum L10n {
    /// UserDefaults key (app) holding "system", "en" or "zh-Hans".
    public static let defaultsKey = "language"

    private static let lock = NSLock()
    private static var _override: Language?

    /// Set by the app from its Settings, or by the CLI from THERMO_LANG; nil follows the system.
    public static var override: Language? {
        get { lock.lock(); defer { lock.unlock() }; return _override }
        set { lock.lock(); _override = newValue; lock.unlock() }
    }

    public static var current: Language { override ?? system }

    public static var system: Language {
        if let env = ProcessInfo.processInfo.environment["THERMO_LANG"], let l = parse(env) { return l }
        for id in Locale.preferredLanguages {
            if let l = parse(id) { return l }
        }
        return .english
    }

    /// "zh", "zh-Hans-CN", "zh_CN", "en-US" … → a supported language.
    public static func parse(_ id: String) -> Language? {
        let l = id.lowercased().replacingOccurrences(of: "_", with: "-")
        if l.hasPrefix("zh") { return .simplifiedChinese }
        if l.hasPrefix("en") { return .english }
        return nil
    }

    /// Applies the app's stored preference ("system" or a language code).
    public static func apply(preference: String?) {
        override = preference.flatMap { $0 == "system" ? nil : Language(rawValue: $0) }
    }
}

/// Translates an English format string. Use positional arguments (`%1$@`, `%2$@`) so translations
/// can reorder them; pass every argument as a String.
public func tr(_ key: String, _ args: String...) -> String {
    let format = L10n.current.table?[key] ?? key
    guard !args.isEmpty else { return format }
    return String(format: format, locale: nil, arguments: args.map { $0 as NSString })
}
