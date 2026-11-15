import AgentCore
import SystemServicesAPI
import ThermoKit
import ThermoL10n

package enum FanPolicyJournal {
    /// A fan mode change is a change Thermo made to the Mac, so History lists it with what each fan was asked for.
    package static func record(_ changes: [(Int, FanPolicy)], active: [Int: FanPolicy]?, error: String?, fans: [FanReading]) {
        guard let first = changes.first else { return }
        let items = changes.map { fan, policy -> OperationRecord.Item in
            let name = fan < 0 ? tr("All fans") : fans.first { $0.id == fan }?.displayName ?? tr("Fan %1$@", String(fan))
            return .init(target: name, status: fanChangeApplied(fan: fan, policy: policy, active: active, error: error) ? "done" : "failed",
                         detail: FanPolicyText.label(policy))
        }
        OperationJournal.record(OperationRecord(feature: "fans", action: "policy", subject: FanPolicyText.label(first.1), items: items))
    }

    /// The helper may clamp a speed or curve to the fan's range, so match the mode, not exact numbers.
    /// Automatic is the helper's default: it drops the fan's entry rather than storing `.auto`.
    package static func fanChangeApplied(fan: Int, policy: FanPolicy, active: [Int: FanPolicy]?, error: String?) -> Bool {
        error == nil && (fan < 0 || active.map { sameMode($0[fan] ?? .auto, policy) } == true)
    }

    package static func sameMode(_ a: FanPolicy, _ b: FanPolicy) -> Bool {
        switch (a, b) {
        case (.auto, .auto), (.fixed, .fixed), (.curve, .curve): return true
        default: return false
        }
    }

}
