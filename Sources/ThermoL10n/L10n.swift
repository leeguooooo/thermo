import Foundation

/// UI languages. The English string is the key; other languages are tables keyed by it.
/// Tables live in code (not .lproj resources) because the CLI ships as a single binary and the app
/// bundle is assembled by scripts/build.sh, neither of which carries SwiftPM resource bundles.
public enum Language: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case japanese = "ja"

    public var id: String { rawValue }

    /// The language's own name, for a picker.
    public var displayName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .japanese: return "日本語"
        }
    }

    var table: [String: String]? {
        switch self {
        case .english: return nil
        case .simplifiedChinese: return zhHansWithMenuBar
        case .japanese: return ja
        }
    }
}

public enum L10n {
    /// UserDefaults key (app) holding "system", "en", "zh-Hans" or "ja".
    public static let defaultsKey = "language"

    private static let lock = NSLock()
    private static var _override: Language?
    /// `system` copies the environment and reads the locale; `tr` runs for every visible string.
    private static var _system: Language?

    /// Set by the app from its Settings, or by the CLI from THERMO_LANG; nil follows the system.
    public static var override: Language? {
        get { lock.lock(); defer { lock.unlock() }; return _override }
        set { lock.lock(); _override = newValue; lock.unlock() }
    }

    public static var current: Language {
        lock.lock()
        if let language = _override ?? _system { lock.unlock(); return language }
        lock.unlock()
        let found = system
        lock.lock(); defer { lock.unlock() }
        _system = found
        return _override ?? found
    }

    public static var system: Language {
        if let env = ProcessInfo.processInfo.environment["THERMO_LANG"], let l = parse(env) { return l }
        // Japanese only covers a few screens so far, so following the system skips it and falls
        // through to the next preferred language; choosing 日本語 explicitly still applies it.
        for id in Locale.preferredLanguages {
            if let l = parse(id), l != .japanese { return l }
        }
        return .english
    }

    /// "zh", "zh-Hans-CN", "zh_CN", "en-US" … → a supported language.
    public static func parse(_ id: String) -> Language? {
        let l = id.lowercased().replacingOccurrences(of: "_", with: "-")
        if l.hasPrefix("zh") { return .simplifiedChinese }
        if l.hasPrefix("en") { return .english }
        if l.hasPrefix("ja") { return .japanese }
        return nil
    }

    /// Applies the app's stored preference ("system" or a language code).
    public static func apply(preference: String?) {
        override = preference.flatMap { $0 == "system" ? nil : Language(rawValue: $0) }
        lock.lock(); _system = nil; lock.unlock()
    }
}

/// Translates an English format string. Use positional arguments (`%1$@`, `%2$@`) so translations
/// can reorder them; pass every argument as a String.
public func tr(_ key: String, _ args: String...) -> String {
    let format = L10n.current.table?[key] ?? key
    guard !args.isEmpty else { return format }
    return String(format: format, locale: nil, arguments: args.map { $0 as NSString })
}

public extension Language {
    /// The locale for dates and numbers shown in this language, so an English UI never shows
    /// Chinese-format dates just because the Mac's region is China (and the other way round).
    var locale: Locale {
        switch self {
        case .english:
            // Keep the user's own English region (en_GB dates differ from en_US) when they have one.
            return Locale.current.language.languageCode?.identifier == "en" ? Locale.current : Locale(identifier: "en_US")
        case .simplifiedChinese: return Locale(identifier: "zh_CN")
        case .japanese: return Locale(identifier: "ja_JP")
        }
    }
}

public extension L10n {
    /// Locale for the language the UI is showing right now.
    static var locale: Locale { current.locale }
}
