import Foundation

public struct BatteryChargeState: Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case off, watching, holding, blocked, recovering }
    public var policy: BatteryChargePolicy = .off
    public var phase: Phase = .blocked
    public var gate: BatteryChargePolicy.Gate = .unknown
    public var ownership: BatteryChargePolicy.Ownership = .none
    public var ownedByCaller = false
    public var sessionID: String?
    public var support: BatteryChargeSupport?
    public var percent: Double?
    public var externalPower: Bool?
    public var error: String?
    public init() {}
}

/// Independent from fan/network initialization. All gate, policy and ownership
/// transitions occur on this queue; connection closure is observable immediately.
public final class BatteryHelperCoordinator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.thermo.helper.charging", qos: .utility)
    private let make: @Sendable () throws -> BatteryChargingGate
    private let power: @Sendable () -> BatteryChargePolicy.Observation?
    private let clock: @Sendable () -> TimeInterval
    private let presence: @Sendable () -> BatteryPresence
    private let nativeEligible: @Sendable () -> Bool
    private var controller: BatteryChargingGate?
    private var timer: DispatchSourceTimer?
    private var owner: AWDLConnectionOwner?
    private var removalToken: String?
    private var stopping = false, recoveryPending = true
    private var lastTick: TimeInterval?
    private var powerObservedAt: TimeInterval?
    private var state = BatteryChargeState()

    public init(make: @escaping @Sendable () throws -> BatteryChargingGate = { try BatteryChargeSystem.make() },
                power: @escaping @Sendable () -> BatteryChargePolicy.Observation? = { BatteryChargeSystem.power() },
                clock: @escaping @Sendable () -> TimeInterval = { AWDLSystemClock.now() },
                presence: @escaping @Sendable () -> BatteryPresence = { BatteryChargeSystem.presence() },
                nativeEligible: @escaping @Sendable () -> Bool = { BatteryChargeSystem.nativeLimitEligible },
                tickInterval: TimeInterval = 2) {
        self.make = make; self.power = power; self.clock = clock; self.presence = presence; self.nativeEligible = nativeEligible
        let interval = tickInterval.isFinite && tickInterval > 0 ? min(60, max(0.02, tickInterval)) : 2
        queue.async { [self] in
            initialize()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
        }
    }
    deinit { timer?.cancel() }
    private func initialize() {
        do { controller = try make(); _ = restore() }
        catch { state.phase = .blocked; state.error = error.localizedDescription }
    }
    @discardableResult private func restore() -> Bool {
        guard let controller else { state.phase = .blocked; return false }
        recoveryPending = !controller.recover()
        let observed = controller.observation()
        state.gate = observed.gate; state.ownership = observed.ownership
        state.phase = recoveryPending ? .recovering : (state.policy == .off ? .off : .watching)
        state.error = recoveryPending ? controller.lastError ?? "Charging restoration is unconfirmed" : nil
        return !recoveryPending
    }
    private func stopPolicy() { state.policy = .off; state.sessionID = nil; owner = nil }
    private func updateObservation() {
        state.support = BatteryChargeProbe.support(presence: presence(), availability: controller?.availability() ?? .unavailable, nativeEligible: nativeEligible())
        guard let controller else { return }
        let observed = controller.observation()
        state.gate = observed.gate; state.ownership = observed.ownership
        if state.phase == .holding, observed.gate != .inhibited || observed.ownership != .owned {
            state.phase = .blocked; state.error = controller.lastError ?? "Charging hold readback is unconfirmed"
        }
    }
    @discardableResult private func samplePower() -> BatteryChargePolicy.Observation? {
        if state.support == .noInternalBattery {
            state.percent = nil; state.externalPower = nil; powerObservedAt = nil; return nil
        }
        let sample = power(), now = clock()
        let fresh = sample.map { now.isFinite && now >= 0 && $0.observedAt.isFinite && $0.observedAt >= 0 && now >= $0.observedAt && now - $0.observedAt <= 30 } ?? false
        state.percent = fresh ? sample?.percent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil } : nil
        state.externalPower = fresh ? sample?.externalPower : nil
        powerObservedAt = fresh ? sample?.observedAt : nil
        return sample
    }
    private var supportReason: String {
        switch state.support ?? .unknown {
        case .noInternalBattery: return "No internal battery was reported by this Mac."
        case .systemSettings: return "Manage the system charging limit in Battery settings."
        case .unsupported: return "No supported charging control was found on this Mac."
        case .unknown: return "Charging support has not been verified."
        case .smc: return "Charging control is available."
        }
    }
    private func evaluate() throws {
        guard let controller else { throw BatteryGateError(state.error ?? "Charging controller is unavailable") }
        updateObservation()
        let sample = samplePower(), now = clock()
        if state.support != .smc {
            let reason = supportReason
            if state.support != .unknown { stopPolicy() }
            guard restore() else { throw BatteryGateError(state.error ?? "Charging restoration is unconfirmed") }
            state.phase = state.policy == .off ? .off : .blocked; state.error = reason
            return
        }
        switch state.policy.decision(observation: sample, now: now, gate: state.gate, ownership: state.ownership) {
        case .inhibit:
            guard owner?.isClosed == false else { throw BatteryGateError("Charging connection closed before apply") }
            try controller.inhibit(); updateObservation()
            guard state.gate == .inhibited, state.ownership == .owned else { throw BatteryGateError("Charging hold readback is unconfirmed") }
            state.phase = .holding; state.error = nil
        case .restoreOwned:
            guard restore() else { throw BatteryGateError(state.error ?? "Charging restoration is unconfirmed") }
            if state.percent == nil || state.externalPower == nil {
                state.phase = .blocked; state.error = "Fresh battery or power state is unavailable"
            }
        case .recoveryRequired:
            _ = restore()
            throw BatteryGateError(state.error ?? "Charging control changed; enable the policy again after recovery")
        case .externalHold:
            state.phase = .blocked; state.error = "Charging is held outside this connection; Thermo will not change it"
        case .observationUnavailable:
            state.phase = .blocked; state.error = controller.lastError ?? "Fresh battery or charging state is unavailable"
        case .leaveUnchanged:
            state.phase = state.ownership == .owned ? .holding : (state.policy == .off ? .off : .watching)
            state.error = nil
        }
    }
    private func tick() {
        if controller == nil { initialize() }
        guard controller != nil else { return }
        if owner?.isClosed == true { stopPolicy(); _ = restore() }
        if recoveryPending { _ = restore(); return }
        guard !stopping, removalToken == nil, state.policy != .off else { return }
        let now = clock()
        defer { lastTick = now.isFinite ? now : nil }
        if let previous = lastTick, !now.isFinite || now < previous || now - previous > 30 {
            _ = restore(); return // Sleep/clock gap: release before a fresh later policy tick.
        }
        do { try evaluate() }
        catch { let error = error.localizedDescription; stopPolicy(); _ = restore(); state.error = error }
    }
    public func setPolicy(_ policy: BatteryChargePolicy, owner: AWDLConnectionOwner,
                          sessionID: String = UUID().uuidString,
                          reply: @escaping @Sendable (String?) -> Void) {
        queue.async {
            guard UUID(uuidString: sessionID) != nil else { reply("Invalid charging session identifier"); return }
            guard !owner.isClosed, !self.stopping, self.removalToken == nil else { reply("Charging connection is closed or helper is preparing to stop"); return }
            guard self.owner == nil || self.owner?.id == owner.id else { reply("Another connection owns charging control"); return }
            guard self.controller != nil else { reply(self.state.error ?? "Charging controller is unavailable"); return }
            self.updateObservation()
            guard policy == .off || self.state.support == .smc else { reply(self.supportReason); return }
            if self.recoveryPending, !self.restore() { reply(self.state.error); return }
            if policy != .limit80 {
                self.stopPolicy()
                guard self.restore() else { reply(self.state.error); return }
            }
            self.state.policy = policy; self.owner = policy == .off ? nil : owner
            self.state.sessionID = policy == .off ? nil : sessionID
            self.lastTick = self.clock()
            do {
                if policy != .off { try self.evaluate() }
                guard !owner.isClosed else { throw BatteryGateError("Charging connection closed during policy change") }
                reply(nil)
            } catch {
                let error = error.localizedDescription; self.stopPolicy(); _ = self.restore(); self.state.error = error; reply(error)
            }
        }
    }
    public func state(owner: AWDLConnectionOwner, reply: @escaping @Sendable (Data) -> Void) {
        queue.async {
            self.updateObservation()
            self.samplePower()
            var value = self.state
            let now = self.clock()
            if self.powerObservedAt.map({ now.isFinite && now >= $0 && now - $0 <= 30 }) != true {
                value.percent = nil; value.externalPower = nil
            }
            value.ownedByCaller = !owner.isClosed && self.owner?.id == owner.id
            reply((try? PolicyCoding.encoder().encode(value)) ?? Data())
        }
    }
    public func disconnected(owner: AWDLConnectionOwner) {
        owner.close()
        queue.async {
            if self.owner?.id == owner.id { self.stopPolicy(); _ = self.restore() }
            if self.removalToken?.hasPrefix(owner.id + ":") == true { self.removalToken = nil }
        }
    }
    public func prepareRemoval(_ prepare: Bool, token: String, owner: AWDLConnectionOwner,
                               reply: @escaping @Sendable (String?) -> Void) {
        queue.async {
            guard !prepare || !owner.isClosed else { reply("Charging connection is closed"); return }
            guard self.removalToken == nil || self.removalToken == token else { reply("Another connection is preparing helper removal"); return }
            if prepare {
                self.removalToken = token; self.stopPolicy()
                let restored = self.restore()
                if owner.isClosed { self.removalToken = nil }
                reply(restored ? nil : self.state.error ?? "Charging restoration is unconfirmed")
            } else { self.removalToken = nil; reply(nil) }
        }
    }
    public func shutdown(reason: String, reply: @escaping @Sendable (Bool) -> Void) {
        queue.async { self.stopping = true; self.stopPolicy(); reply(self.restore()) }
    }
}
