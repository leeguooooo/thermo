import ThermoKit

/// Accuracy follows the selected feature; the default menu-bar CPU reading stays inexpensive.
struct SamplingPlan {
    var scope: SamplerScope
    var parts: SamplerParts
    var groups: Set<SensorGroup>?

    static func make(visible: Bool, includeUnnamed: Bool, metric: TitleMetric, alerts: Bool) -> SamplingPlan {
        if visible {
            return SamplingPlan(scope: includeUnnamed ? .all : .known, parts: .everything, groups: nil)
        }
        let parts: SamplerParts = metric == .power ? [.temperatures, .fans, .power] : [.temperatures, .fans]
        if metric == .hottest || alerts {
            return SamplingPlan(scope: .known, parts: parts, groups: nil)
        }
        return SamplingPlan(scope: .essential, parts: parts, groups: [.cpu, .gpu])
    }
}
