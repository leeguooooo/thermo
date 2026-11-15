import SystemServicesAPI
import Darwin
import Foundation
import CleanKit
import ThermoKit
import ThermoL10n

extension MenuMetric {
    var label: String {
        switch self {
        case .cpu: return tr("CPU temperature")
        case .hottest: return tr("Hottest sensor")
        case .fan: return tr("Fan speed")
        case .power: return tr("System power")
        case .cpuUsage: return tr("CPU usage")
        case .memory: return tr("Memory used")
        case .download: return tr("Download speed")
        case .upload: return tr("Upload speed")
        }
    }
}

extension MenuClickAction {
    var label: String {
        switch self {
        case .panel: return tr("Panel")
        case .console: return tr("Main console")
        case .menu: return tr("Menu")
        }
    }
}


struct MenuDisplay {
    var text: String
    var tooltip: String
    var showIcon: Bool
    var stacked: Bool

    static func make(preferences p: MenuBarPreferences, snapshot: Snapshot?, live: MenuLiveValues,
                     fahrenheit: Bool, marker: String = "", now: Date = Date(),
                     sensorReadStarted: Date? = nil, validAfter: Date = .distantPast) -> MenuDisplay {
        // Snapshot timestamps mark completion. A read that straddled wake or a
        // settings change must not make its earlier observations look fresh.
        let freshSensors = snapshot.map {
            let started = sensorReadStarted ?? $0.timestamp
            return started >= validAfter && $0.timestamp >= validAfter &&
                (0...15).contains(now.timeIntervalSince(started)) &&
                (0...15).contains(now.timeIntervalSince($0.timestamp))
        } ?? false
        let freshLive = live.sampled >= validAfter && (0...15).contains(now.timeIntervalSince(live.sampled))
        func number(_ value: Double?, unit: String, scale: Double = 1) -> String {
            guard let value, value.isFinite, value >= 0 else { return "— " + unit }
            return String(format: "%.0f %@", value * scale, unit)
        }
        func value(_ metric: MenuMetric) -> String {
            switch metric {
            case .cpu, .hottest:
                let c = freshSensors ? (metric == .cpu ? snapshot?.cpu : snapshot?.maximumKnownTemperature) : nil
                return number(c.map { fahrenheit ? $0 * 9 / 5 + 32 : $0 }, unit: fahrenheit ? "°F" : "°C")
            case .fan:
                let fans = freshSensors ? snapshot?.fans : nil
                let maximum = fans?.compactMap(\.rpm).max()
                let partial = maximum != nil && (fans?.contains { $0.rpm == nil } ?? false)
                return (partial ? "≥ " : "") + number(maximum, unit: "rpm")
            case .power: return number(freshSensors ? snapshot?.systemPower : nil, unit: "W")
            case .cpuUsage: return number(freshLive ? live.cpu : nil, unit: "%")
            case .memory: return number(freshLive ? live.memory : nil, unit: "GiB", scale: 1 / 1_073_741_824)
            case .download, .upload:
                let bytes = freshLive ? (metric == .download ? live.download : live.upload) : nil
                return (metric == .download ? "↓ " : "↑ ") + number(bytes, unit: "KiB/s", scale: 1 / 1024)
            }
        }
        let metrics = [p.primary] + (p.secondary.map { [$0] } ?? [])
        let values = metrics.map(value)
        let stacked = p.layout == .stacked && metrics.count == 2 && p.presentation != .icon
        let data = p.presentation == .icon ? "" : values.joined(separator: stacked ? "\n" : " · ")
        let text = [data, marker].filter { !$0.isEmpty }.joined(separator: " ")
        let tip = zip(metrics, values).map { tr("%1$@: %2$@", $0.label, $1) }.joined(separator: " · ")
        let awake = marker.isEmpty ? "" : tr("%1$@: %2$@", tr("Keep awake"), marker)
        return MenuDisplay(text: text, tooltip: ["Thermo", tip, awake].filter { !$0.isEmpty }.joined(separator: " · "),
                           showIcon: p.presentation != .data, stacked: stacked)
    }
}
