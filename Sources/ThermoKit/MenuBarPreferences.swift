import Foundation

/// Shared by the app and CLI. Raw values are the persistent and scripting API.
public enum MenuMetric: String, CaseIterable, Identifiable, Sendable {
    case cpu, hottest, fan, power, cpuUsage, memory, download, upload
    public var id: String { rawValue }
}
public enum MenuPresentation: String, CaseIterable, Identifiable, Sendable {
    case both, icon, data
    public var id: String { rawValue }
}
public enum MenuLayout: String, CaseIterable, Identifiable, Sendable {
    case horizontal, stacked
    public var id: String { rawValue }
}
public enum MenuClickAction: String, CaseIterable, Identifiable, Sendable {
    case panel, console
    public var id: String { rawValue }
}

public struct MenuBarPreferences: Equatable, Sendable {
    public static let primaryKey = "menuPrimary"
    public static let secondaryKey = "menuSecondary"
    public static let presentationKey = "menuPresentation"
    public static let layoutKey = "menuLayout"
    public static let leftKey = "menuLeftClick"
    public static let rightKey = "menuRightClick"
    private static let migratedKey = "menuMigratedTitleMetric"
    public var primary: MenuMetric = .cpu
    public var secondary: MenuMetric?
    public var presentation: MenuPresentation = .both
    public var layout: MenuLayout = .horizontal
    public var left: MenuClickAction = .panel
    public var right: MenuClickAction = .panel
    public init() {}
    public var metrics: Set<MenuMetric> {
        presentation == .icon ? [] : Set([primary] + (secondary.map { [$0] } ?? []))
    }

    public static func legacy(_ value: String) -> MenuBarPreferences {
        var result = MenuBarPreferences()
        switch value {
        case "hottest": result.primary = .hottest
        case "fan": result.primary = .fan
        case "power": result.primary = .power
        case "cpuAndFan": result.secondary = .fan
        case "iconOnly": result.presentation = .icon
        default: break
        }
        return result
    }

    /// Explicit legacy CLI writes must work even when the old value has not changed.
    public static func applyLegacy(_ value: String, to d: UserDefaults) {
        let p = legacy(value)
        d.set(p.primary.rawValue, forKey: primaryKey)
        d.set(p.secondary?.rawValue ?? "none", forKey: secondaryKey)
        d.set(p.presentation.rawValue, forKey: presentationKey)
        d.set(value, forKey: migratedKey)
    }

    public static func read(_ d: UserDefaults = .standard) -> MenuBarPreferences {
        var p = MenuBarPreferences()
        p.primary = MenuMetric(rawValue: d.string(forKey: primaryKey) ?? "") ?? .cpu
        p.secondary = MenuMetric(rawValue: d.string(forKey: secondaryKey) ?? "")
        p.presentation = MenuPresentation(rawValue: d.string(forKey: presentationKey) ?? "") ?? .both
        p.layout = MenuLayout(rawValue: d.string(forKey: layoutKey) ?? "") ?? .horizontal
        p.left = MenuClickAction(rawValue: d.string(forKey: leftKey) ?? "") ?? .panel
        p.right = MenuClickAction(rawValue: d.string(forKey: rightKey) ?? "") ?? .panel
        let old = d.string(forKey: "titleMetric") ?? "cpu"
        if d.string(forKey: migratedKey) != old {
            let migrated = legacy(old)
            p.primary = migrated.primary; p.secondary = migrated.secondary; p.presentation = migrated.presentation
        }
        return p
    }

    public static func normalize(_ d: UserDefaults = .standard) {
        let stored = d.string(forKey: "titleMetric") ?? "cpu"
        let legacy = ["cpu", "hottest", "fan", "power", "cpuAndFan", "iconOnly"].contains(stored) ? stored : "cpu"
        if d.string(forKey: "titleMetric") != legacy { d.set(legacy, forKey: "titleMetric") }
        if d.string(forKey: migratedKey) != legacy { applyLegacy(legacy, to: d) }
        let p = read(d)
        let values = [primaryKey: p.primary.rawValue, secondaryKey: p.secondary?.rawValue ?? "none",
                      presentationKey: p.presentation.rawValue, layoutKey: p.layout.rawValue,
                      leftKey: p.left.rawValue, rightKey: p.right.rawValue]
        for (key, value) in values where d.string(forKey: key) != value { d.set(value, forKey: key) }
    }
}
