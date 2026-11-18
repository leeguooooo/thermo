import Foundation
import ThermoKit
import ThermoL10n

package enum TitleMetric: String, CaseIterable, Identifiable {
    case cpu, hottest, fan, cpuAndFan, power, iconOnly
    package var id: String { rawValue }
    package var label: String {
        switch self {
        case .cpu: return tr("CPU temperature")
        case .hottest: return tr("Hottest sensor")
        case .fan: return tr("Fan speed")
        case .cpuAndFan: return tr("CPU temperature + fan")
        case .power: return tr("System power")
        case .iconOnly: return tr("Icon only")
        }
    }
}


package enum Settings {
    package static let slowdownAlerts="slowdownAlerts"
    /// Off by default: left-behind tool processes are ended without asking once they add up.
    package static let autoEndLeftBehindTools="autoEndLeftBehindTools"
    package static let interval = "interval"
    package static let titleMetric = "titleMetric"
    package static let alertsEnabled = "alertsEnabled"
    /// Whether heat turns "stay awake with the lid closed" off (default on).
    package static let lidAwakeHeatGuard = "lidAwakeHeatGuard"
    package static let alertThreshold = "alertThreshold"
    package static let fahrenheit = "fahrenheit"
    package static let unnamedSensors = "unnamedSensors"
    /// Show the Dock icon (on by default: a menu bar icon alone is easy to lose, e.g. behind the notch).
    package static let showInDock = "showInDock"

    package static func intervalValue(_ value: Double) -> Double {
        [0.5, 1, 2, 5].contains(value) ? value : 2
    }

    package static func thresholdValue(_ value: Double) -> Double {
        value.isFinite && (60...105).contains(value) ? value : 90
    }

    package static func thresholdText(_ value: Double, fahrenheit: Bool) -> String {
        let celsius = thresholdValue(value)
        let displayed = fahrenheit ? ((celsius * 9 / 5 + 32) * 10).rounded() / 10 : celsius
        return String(format: "%g", displayed)
    }

    package static func normalize(_ defaults: UserDefaults = .standard) {
        let numbers = [(interval, intervalValue(defaults.double(forKey: interval))),
                       (alertThreshold, thresholdValue(defaults.double(forKey: alertThreshold)))]
        for (key, value) in numbers where (defaults.object(forKey: key) as? NSNumber)?.doubleValue != value {
            defaults.set(value, forKey: key)
        }
        if TitleMetric(rawValue: defaults.string(forKey: titleMetric) ?? "") == nil {
            defaults.set(TitleMetric.cpu.rawValue, forKey: titleMetric)
        }
        MenuBarPreferences.normalize(defaults)
        let language = defaults.string(forKey: L10n.defaultsKey) ?? "system"
        if language != "system", Language(rawValue: language) == nil {
            defaults.set("system", forKey: L10n.defaultsKey)
        }
    }

    package static func register(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            showInDock: true,
            lidAwakeHeatGuard: true,
            slowdownAlerts: true,
            interval: 2.0, titleMetric: TitleMetric.cpu.rawValue,
            alertsEnabled: false, alertThreshold: 90.0, fahrenheit: false,
        ])
        normalize(defaults)
    }
}

