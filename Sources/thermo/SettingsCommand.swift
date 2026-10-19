import Foundation
import ThermoKit

/// `thermo settings [KEY [VALUE]]`: the app's settings (UserDefaults domain dev.thermo.app), so
/// agents and scripts can do what the Settings tab does.
struct SettingsCommand {
    let app: App

    struct Setting {
        let key: String
        let defaultsKey: String
        let help: String
        let parse: (String) -> Any?
        let show: (Any?) -> String
    }

    static let domain = "dev.thermo.app"

    static func apply(_ setting: Setting, value: Any, to defaults: UserDefaults) {
        MenuBarPreferences.normalize(defaults)
        defaults.set(value, forKey: setting.defaultsKey)
        if setting.defaultsKey == "titleMetric", let legacy = value as? String {
            MenuBarPreferences.applyLegacy(legacy, to: defaults)
        }
        MenuBarPreferences.normalize(defaults)
    }

    static func bool(_ s: String) -> Any? {
        switch s.lowercased() { case "on", "yes", "true", "1": return true; case "off", "no", "false", "0": return false; default: return nil }
    }

    static let all: [Setting] = [
        Setting(key: "menubar-primary", defaultsKey: MenuBarPreferences.primaryKey, help: MenuMetric.allCases.map(\.rawValue).joined(separator: " | "),
                parse: { value in MenuMetric.allCases.first { $0.rawValue.lowercased() == value.lowercased() }?.rawValue },
                show: { MenuMetric(rawValue: $0 as? String ?? "")?.rawValue ?? "cpu" }),
        Setting(key: "menubar-secondary", defaultsKey: MenuBarPreferences.secondaryKey, help: "none | " + MenuMetric.allCases.map(\.rawValue).joined(separator: " | "),
                parse: { value in value.lowercased() == "none" ? "none" : MenuMetric.allCases.first { $0.rawValue.lowercased() == value.lowercased() }?.rawValue },
                show: { MenuMetric(rawValue: $0 as? String ?? "")?.rawValue ?? "none" }),
        Setting(key: "menubar-presentation", defaultsKey: MenuBarPreferences.presentationKey, help: "both | icon | data",
                parse: { MenuPresentation(rawValue: $0.lowercased())?.rawValue },
                show: { MenuPresentation(rawValue: $0 as? String ?? "")?.rawValue ?? "both" }),
        Setting(key: "menubar-layout", defaultsKey: MenuBarPreferences.layoutKey, help: "horizontal | stacked",
                parse: { MenuLayout(rawValue: $0.lowercased())?.rawValue },
                show: { MenuLayout(rawValue: $0 as? String ?? "")?.rawValue ?? "horizontal" }),
        Setting(key: "menubar-left-click", defaultsKey: MenuBarPreferences.leftKey, help: "panel | console",
                parse: { MenuClickAction(rawValue: $0.lowercased())?.rawValue },
                show: { MenuClickAction(rawValue: $0 as? String ?? "")?.rawValue ?? "panel" }),
        Setting(key: "menubar-right-click", defaultsKey: MenuBarPreferences.rightKey, help: "panel | console",
                parse: { MenuClickAction(rawValue: $0.lowercased())?.rawValue },
                show: { MenuClickAction(rawValue: $0 as? String ?? "")?.rawValue ?? "panel" }),
        Setting(key: "menubar", defaultsKey: "titleMetric", help: "cpu | hottest | fan | cpu+fan | power | icon",
                parse: { ["cpu": "cpu", "hottest": "hottest", "fan": "fan", "cpu+fan": "cpuAndFan", "power": "power", "icon": "iconOnly"][$0.lowercased()] },
                show: { v in ["cpuAndFan": "cpu+fan", "iconOnly": "icon"][v as? String ?? ""] ?? (v as? String ?? "cpu") }),
        Setting(key: "interval", defaultsKey: "interval", help: "seconds between samples: 0.5 | 1 | 2 | 5",
                parse: { Double($0).flatMap { [0.5, 1, 2, 5].contains($0) ? $0 : nil } },
                show: { v in String(format: "%g", (v as? Double) ?? 2) }),
        Setting(key: "alerts", defaultsKey: "alertsEnabled", help: "on | off (notify when hot)",
                parse: bool, show: { ($0 as? Bool ?? false) ? "on" : "off" }),
        Setting(key: "alert-at", defaultsKey: "alertThreshold", help: "°C, 60–105",
                parse: { Double($0).flatMap { (60...105).contains($0) ? $0 : nil } },
                show: { v in String(format: "%g", (v as? Double) ?? 90) }),
        Setting(key: "slowdown-alerts", defaultsKey: "slowdownAlerts", help: "on | off (notify before slowdowns)",
                parse: bool, show: { ($0 as? Bool ?? true) ? "on" : "off" }),
        Setting(key: "unnamed-sensors", defaultsKey: "unnamedSensors", help: "on | off (include unnamed readings in Sensors)",
                parse: bool, show: { ($0 as? Bool ?? false) ? "on" : "off" }),
        Setting(key: "fahrenheit", defaultsKey: "fahrenheit", help: "on | off",
                parse: bool, show: { ($0 as? Bool ?? false) ? "on" : "off" }),
        Setting(key: "language", defaultsKey: "language", help: "system | en | zh-Hans",
                parse: { v in ["system", "en", "zh-Hans"].first(where: { $0.lowercased() == v.lowercased() }) },
                show: { ($0 as? String) ?? "system" }),
        Setting(key: "dock", defaultsKey: "showInDock", help: "on | off (Dock icon)",
                parse: bool, show: { ($0 as? Bool ?? true) ? "on" : "off" }),
    ]

    func run(_ rest: [String]) throws {
        var args = rest
        if args.count == 1, let eq = args[0].firstIndex(of: "=") {
            args = [String(args[0][..<eq]), String(args[0][args[0].index(after: eq)...])]
        }
        guard let d = UserDefaults(suiteName: Self.domain) else { throw CLIError("cannot open settings") }
        let menu = MenuBarPreferences.read(d)
        func current(_ s: Setting) -> Any? {
            switch s.defaultsKey {
            case MenuBarPreferences.primaryKey: return menu.primary.rawValue
            case MenuBarPreferences.secondaryKey: return menu.secondary?.rawValue ?? "none"
            case MenuBarPreferences.presentationKey: return menu.presentation.rawValue
            case MenuBarPreferences.layoutKey: return menu.layout.rawValue
            case MenuBarPreferences.leftKey: return menu.left.rawValue
            case MenuBarPreferences.rightKey: return menu.right.rawValue
            default: return d.object(forKey: s.defaultsKey)
            }
        }
        func exported(_ values: [(key: String, value: String)]) -> Bool {
            if app.args.has("json") { print(Export.json(Dictionary(uniqueKeysWithValues: values))); return true }
            if app.args.has("csv") { print(Export.settingsCSV(values)); return true }
            return false
        }

        switch args.count {
        case 0:
            if exported(Self.all.map { ($0.key, $0.show(current($0))) }) { return }
            for s in Self.all {
                print(pad(s.key, 12) + pad(s.show(current(s)), 10) + app.style.dim(s.help))
            }
            print(app.style.dim("change one: thermo settings KEY VALUE  (a running Thermo applies it right away)"))
        case 1, 2:
            guard let s = Self.all.first(where: { $0.key == args[0] }) else {
                throw CLIError("unknown setting '\(args[0])'; one of " + Self.all.map(\.key).joined(separator: ", "))
            }
            if args.count == 1 {
                let value = s.show(current(s))
                if !exported([(s.key, value)]) { print(value) }
                return
            }
            guard let v = s.parse(args[1]) else { throw CLIError("\(s.key) expects \(s.help)") }
            if app.args.has("dry-run") {
                if !exported([(s.key, s.show(v))]) { print("planned: " + s.key + " = " + s.show(v)) }
                return
            }
            Self.apply(s, value: v, to: d)
            d.synchronize()
            // Tell a running Thermo to re-read its settings now.
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("dev.thermo.settingsChanged"), object: nil, userInfo: nil, deliverImmediately: true)
            if !exported([(s.key, s.show(v))]) { print("\(s.key) = \(s.show(v))") }
        default:
            throw CLIError("usage: thermo settings [KEY [VALUE]]")
        }
    }
}
