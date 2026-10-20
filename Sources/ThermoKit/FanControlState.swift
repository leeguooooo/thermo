import Foundation

public struct FanControlObservation: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case automatic, manual }
    public var mode: Mode
    public var target: Double?
    public var checkedAt: Date
    public init(mode: Mode, target: Double? = nil, checkedAt: Date = Date()) {
        self.mode = mode; self.target = target; self.checkedAt = checkedAt
    }
}

/// Desired policies and the helper's last register checks are separate facts.
/// Observations do not assert that the rotor has reached the target RPM.
public struct FanControlState: Codable, Equatable, Sendable {
    public enum Verification: String { case unavailable, failed, suspended, pending, checked }
    public var policies: [Int: FanPolicy]
    public var observations: [Int: FanControlObservation]
    public var suspended: Bool
    public var suspensionReason: FanPolicySuspension?
    public var failure: String?
    public var observationsSupported: Bool

    /// References in saved control state, independent of the current SMC inventory.
    public var referencedFanIDs: [Int] { Set(policies.keys).union(observations.keys).sorted() }

    public init(policies: [Int: FanPolicy], observations: [Int: FanControlObservation] = [:],
                suspended: Bool = false, suspensionReason: FanPolicySuspension? = nil, failure: String? = nil, observationsSupported: Bool = true) {
        self.policies = policies; self.observations = observations
        self.suspended = suspended; self.suspensionReason = suspensionReason; self.failure = failure; self.observationsSupported = observationsSupported
    }

    /// Older clients only know an "active policy" dictionary. Refuse to send it
    /// while the observed mode cannot support that interpretation.
    public var legacyError: String? {
        if let failure { return failure }
        if suspended { return suspensionReason == .temperatureUnavailable ? "fan policies suspended after required temperature readings were lost" : "fan policies are suspended for thermal safety" }
        for (id, policy) in policies where policy != .auto {
            guard observations[id]?.mode == .manual, verification(for: id) == .checked else { return "fan \(id): policy accepted; manual control has not been confirmed" }
        }
        return nil
    }

    public func verification(for fan: Int) -> Verification {
        guard observationsSupported else { return .unavailable }
        if failure != nil { return .failed }
        let observation = observations[fan]
        if suspended, observation?.mode != .manual { return .suspended }
        guard let observation else { return .pending }
        guard observation.checkedAt.timeIntervalSince1970.isFinite else { return .unavailable }
        if observation.mode == .manual {
            guard let target = observation.target, target.isFinite, target >= 0 else { return .unavailable }
        }
        return .checked
    }
}
