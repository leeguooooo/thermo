import Foundation
import ThermoKit
import ThermoL10n

enum FanControlPresentation {
    static func rpm(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? tr("unknown") }
    static func speedSummary(_ fans: [FanReading]) -> String? {
        guard !fans.isEmpty else { return nil }
        let speed = fans.compactMap(\.rpm).max()
        let prefix = speed != nil && fans.contains { $0.rpm == nil } ? "≥ " : ""
        return prefix + tr("%1$@ rpm", rpm(speed))
    }
    static func observation(_ state: FanControlState?, fan: Int) -> String {
        guard let state, state.observationsSupported else { return tr("Hardware verification unavailable") }
        if state.verification(for: fan) == .unavailable { return tr("Hardware verification unavailable") }
        if let failure = state.failure { return tr("Control error: %1$@", failure) }
        if state.verification(for: fan) == .suspended {
            return state.suspensionReason == .temperatureUnavailable ? tr("Temperature readings were lost; waiting for stable safe readings") : tr("Manual policies suspended for thermal safety")
        }
        guard let observation = state.observations[fan] else { return tr("Waiting for hardware verification") }
        switch observation.mode {
        case .automatic: return tr("Last register check: automatic control")
        case .manual:
            guard let target = observation.target, target.isFinite, target >= 0 else { return tr("Hardware verification unavailable") }
            return tr("Last register check: manual target %1$@ rpm", String(format: "%.0f", target))
        }
    }
}
