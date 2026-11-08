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
    /// `speedSummary` and the cards use the reported speed, not the raw one: see `FanReading.reportedRPM`.
    static func speedSummary(_ fans: [FanReading], stopped: Set<Int> = []) -> String? {
        guard !fans.isEmpty else { return nil }
        // No fan has a usable speed (the SMC's momentary 0, or an unreadable fan): the sidebar and
        // status menu show nothing rather than "unknown rpm"; the Fans page still says unknown.
        guard let speed = fans.compactMap({ $0.reportedRPM(stopped: stopped) }).max() else { return nil }
        let prefix = fans.contains { $0.reportedRPM(stopped: stopped) == nil } ? "≥ " : ""
        return prefix + tr("%1$@ rpm", rpm(speed))
    }
    /// Every fan confirmed at rest: Apple silicon Macs stop their fans while cool.
    static func allStopped(_ fans: [FanReading], stopped: Set<Int>) -> Bool {
        !fans.isEmpty && fans.allSatisfy { $0.rpm == 0 && stopped.contains($0.id) }
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

extension FanReading {
    /// The SMC reports "Fan" / "Fan 2" in English when the hardware has no name of its own.
    var displayName: String {
        if name == "Fan" { return tr("Fan") }
        if name.hasPrefix("Fan "), let n = Int(name.dropFirst(4)) { return tr("Fan %1$@", String(n)) }
        return name
    }
}

extension FanReading {
    /// The speed worth showing. The SMC reports 0 rpm until its first real poll after launch, and a
    /// fan cannot run below its own minimum, so a 0 under that minimum is "not read yet", not a speed.
    var reportedRPM: Double? { reportedRPM(stopped: []) }
    /// `stopped` holds fans whose 0 has persisted (see `Monitor.stoppedFans`): Apple silicon fans
    /// do stop below their spinning minimum, so a lasting 0 is a real reading.
    func reportedRPM(stopped: Set<Int>) -> Double? {
        guard let rpm else { return nil }
        if rpm == 0, let min, min > 0, !stopped.contains(id) { return nil }
        return rpm
    }
}
