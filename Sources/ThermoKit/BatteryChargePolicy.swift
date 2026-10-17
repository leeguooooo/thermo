import Foundation

public enum BatteryFullChargeEndReason: String, Codable, Sendable {
    case fullyCharged, unplugged, observationUnavailable, supportChanged
}

/// Pure policy only. A helper must separately own, persist, apply and read back
/// a charging gate lease before reporting that a requested change succeeded.
public enum BatteryChargePolicy: String, Codable, Sendable {
    case off, limit80, chargeToFull

    public enum Gate: String, Codable, Sendable { case allowed, inhibited, unknown }
    public enum Ownership: String, Codable, Sendable { case none, owned, uncertain }
    public enum Decision: Equatable, Sendable {
        case leaveUnchanged
        case inhibit
        case restoreOwned
        case recoveryRequired
        case externalHold
        case observationUnavailable
    }

    /// `observedAt` and `now` must use the same continuous clock, including sleep.
    /// Optional power state preserves missing IOKit data instead of calling it AC.
    public struct Observation: Sendable {
        public let percent: Double?
        public let externalPower: Bool?
        public let observedAt: TimeInterval

        public init(percent: Double?, externalPower: Bool?, observedAt: TimeInterval) {
            self.percent = percent
            self.externalPower = externalPower
            self.observedAt = observedAt
        }
    }

    /// Mole clears its temporary override when AC/percent can no longer support
    /// continuing it. Unknown input ends the override without claiming full charge.
    public func fullChargeEnd(observation: Observation?, now: TimeInterval) -> BatteryFullChargeEndReason? {
        guard self == .chargeToFull else { return nil }
        guard let observation, now.isFinite, now >= 0, observation.observedAt.isFinite,
              observation.observedAt >= 0, now >= observation.observedAt,
              now - observation.observedAt <= 30 else { return .observationUnavailable }
        if observation.externalPower == false { return .unplugged }
        guard observation.externalPower == true, let percent = observation.percent,
              percent.isFinite, (0...100).contains(percent) else { return .observationUnavailable }
        return percent >= 100 ? .fullyCharged : nil
    }

    /// Stop at 80%, resume below 75%, retain the current hold between them.
    /// Mole's shipped arm64 policy branch uses these same threshold boundaries.
    /// No decision here transfers ownership or asserts actual battery charging.
    public func decision(observation: Observation?, now: TimeInterval,
                         gate: Gate, ownership: Ownership) -> Decision {
        // Unresolved/partial transactions must be recovered before any policy writes.
        if ownership == .uncertain { return .recoveryRequired }
        if gate == .unknown {
            return ownership == .owned ? .recoveryRequired : .observationUnavailable
        }
        if ownership == .none, gate == .inhibited { return .externalHold }

        // Explicit disable/full-charge releases only a lease that belongs to us.
        if self != .limit80 {
            return ownership == .owned ? .restoreOwned : .leaveUnchanged
        }

        guard let observation, now.isFinite, now >= 0,
              observation.observedAt.isFinite, observation.observedAt >= 0,
              now >= observation.observedAt, now - observation.observedAt <= 30,
              let percent = observation.percent, percent.isFinite,
              (0...100).contains(percent), let plugged = observation.externalPower else {
            return ownership == .owned ? .restoreOwned : .observationUnavailable
        }
        if !plugged { return ownership == .owned ? .restoreOwned : .leaveUnchanged }
        if ownership == .owned {
            // The gate changed outside our transaction: do not silently reassert it.
            if gate == .allowed { return .recoveryRequired }
            return percent < 75 ? .restoreOwned : .leaveUnchanged
        }
        return percent >= 80 ? .inhibit : .leaveUnchanged
    }
}
