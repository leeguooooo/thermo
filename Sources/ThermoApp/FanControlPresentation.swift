import Foundation
import ThermoKit
import ThermoL10n

enum FanControlPresentation {
    static func observation(_ state: FanControlState?, fan: Int) -> String {
        guard let state, state.observationsSupported else { return tr("Hardware verification unavailable") }
        if state.verification(for: fan) == .unavailable { return tr("Hardware verification unavailable") }
        if let failure = state.failure { return tr("Control error: %1$@", failure) }
        if state.verification(for: fan) == .suspended { return tr("Manual policies suspended for thermal safety") }
        guard let observation = state.observations[fan] else { return tr("Waiting for hardware verification") }
        switch observation.mode {
        case .automatic: return tr("Last register check: automatic control")
        case .manual:
            guard let target = observation.target, target.isFinite, target >= 0 else { return tr("Hardware verification unavailable") }
            return tr("Last register check: manual target %1$@ rpm", String(format: "%.0f", target))
        }
    }
}
