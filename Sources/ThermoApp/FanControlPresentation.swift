import Foundation
import ThermoKit
import ThermoL10n

enum FanControlPresentation {
    static func selectedPolicy(fan: Int, available: Bool, policies: [Int: FanPolicy], pending: [Int: FanPolicy], state: FanControlState?) -> FanPolicy? {
        if let requested = pending[fan] { return requested }
        guard available else { return nil }
        if let requested = policies[fan] { return requested }
        guard let state, state.verification(for: fan) == .checked,
              state.observations[fan]?.mode == .automatic else { return nil }
        return .auto
    }

    static func missingFanIDs(readings: [FanReading]?, policies: [Int: FanPolicy], pending: [Int: FanPolicy], state: FanControlState?) -> [Int] {
        Set(policies.keys).union(pending.keys).union(state?.referencedFanIDs ?? [])
            .subtracting((readings ?? []).map(\.id)).sorted()
    }
    static func policy(_ policy: FanPolicy) -> String {
        switch policy {
        case .auto: return tr("Auto")
        case .fixed(let r): return r == .infinity ? tr("Max") : tr("%1$@ rpm", String(format: "%.0f", r))
        case .curve(let curve): return tr("Curve") + " · " + curve.pointsText + " (" + curve.sensor.rawValue.uppercased() + ")"
        }
    }
    static func rpm(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? tr("unknown") }
    static func speedSummary(_ fans: [FanReading]) -> String? {
        guard !fans.isEmpty else { return nil }
        let speed = fans.compactMap(\.rpm).max()
        let prefix = speed != nil && fans.contains { $0.rpm == nil } ? "≥ " : ""
        return prefix + tr("%1$@ rpm", rpm(speed))
    }
    static func errorText(_ error: String) -> String {
        if error.contains("no automatic-control readback key") || error.contains("no manual-control readback key") {
            return tr("Fan control could not be verified on this Mac. Open fan settings for details.")
        }
        return error
    }
    static func observation(_ state: FanControlState?, fan: Int) -> String {
        guard let state else { return tr("Hardware verification unavailable") }
        if let failure = state.failure { return tr("Control error: %1$@", errorText(failure)) }
        guard state.observationsSupported, state.verification(for: fan) != .unavailable else { return tr("Hardware verification unavailable") }
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
