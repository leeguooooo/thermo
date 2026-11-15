import SystemServicesAPI
import SystemServicesAPI
import ThermoKit

package enum SamplingSurface: Equatable, Sendable {
    case overview, sensors, compact
}

/// Accuracy follows the selected feature; the default menu-bar CPU reading stays inexpensive.
package struct SamplingPlan {
    package var scope: SamplerScope
    package var parts: SamplerParts
    package var groups: Set<SensorGroup>?

    package static func make(visible: Bool, includeUnnamed: Bool, metric: TitleMetric, alerts: Bool) -> SamplingPlan {
        make(visible: visible, includeUnnamed: includeUnnamed,
             metrics: MenuBarPreferences.legacy(metric.rawValue).metrics, alerts: alerts)
    }

    package static func make(visible: Bool, includeUnnamed: Bool, metrics: Set<MenuMetric>, alerts: Bool,
                     surface: SamplingSurface = .sensors) -> SamplingPlan {
        if visible {
            switch surface {
            case .sensors:
                return SamplingPlan(scope: includeUnnamed ? .all : .known, parts: .everything, groups: nil)
            case .overview:
                return SamplingPlan(scope: .known, parts: [.temperatures, .fans, .power, .battery], groups: nil)
            case .compact:
                var parts: SamplerParts = [.temperatures, .fans]
                if metrics.contains(.power) { parts.insert(.power) }
                return SamplingPlan(scope: .known, parts: parts, groups: nil)
            }
        }
        var parts: SamplerParts = []
        if alerts || !metrics.isDisjoint(with: [.cpu, .hottest]) { parts.insert(.temperatures) }
        if metrics.contains(.fan) { parts.insert(.fans) }
        if metrics.contains(.power) { parts.insert(.power) }
        if metrics.contains(.hottest) || metrics.contains(.power) || alerts {
            return SamplingPlan(scope: .known, parts: parts, groups: nil)
        }
        return SamplingPlan(scope: .essential, parts: parts, groups: [.cpu, .gpu])
    }
}
