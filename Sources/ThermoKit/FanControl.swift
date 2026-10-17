import Foundation

public enum CurveSensor: String, Codable, CaseIterable, Sendable {
    case cpu, gpu, max
}

public struct CurvePoint: Codable, Hashable, Sendable {
    public var temperature: Double
    /// RPM; `.infinity` means the fan's maximum, `0` its minimum (clamped at apply time).
    public var rpm: Double

    public init(_ temperature: Double, _ rpm: Double) { self.temperature = temperature; self.rpm = rpm }

    // JSON cannot carry infinity; encode "max" as -1.
    enum CodingKeys: String, CodingKey { case temperature, rpm }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        temperature = try c.decode(Double.self, forKey: .temperature)
        let r = try c.decode(Double.self, forKey: .rpm)
        rpm = r == -1 ? .infinity : r
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(rpm.isInfinite ? -1 : rpm, forKey: .rpm)
    }
}

public struct FanCurve: Codable, Hashable, Sendable {
    public var points: [CurvePoint]
    public var sensor: CurveSensor

    public init(points: [CurvePoint], sensor: CurveSensor = .cpu) {
        self.points = points.sorted { $0.temperature < $1.temperature }
        self.sensor = sensor
    }

    /// Parse "50:min,70:3000,85:max".
    public init(parsing text: String, sensor: CurveSensor = .cpu) throws {
        var pts: [CurvePoint] = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let kv = part.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let t = Double(kv[0].replacingOccurrences(of: "°", with: "").replacingOccurrences(of: "C", with: "")), t.isFinite else {
                throw FanControlError.badCurve(String(part))
            }
            let rpm: Double
            switch kv[1].lowercased() {
            case "max": rpm = .infinity
            case "min": rpm = 0
            default:
                guard let r = Double(kv[1]), r.isFinite, r >= 0 else { throw FanControlError.badCurve(String(part)) }
                rpm = r
            }
            pts.append(CurvePoint(t, rpm))
        }
        guard !pts.isEmpty else { throw FanControlError.badCurve(text) }
        self.init(points: pts, sensor: sensor)
        try validate()
    }

    /// Linear interpolation; flat beyond the end points. Result is clamped to [min, max].
    public func rpm(at temperature: Double, min lo: Double, max hi: Double) -> Double {
        func resolve(_ r: Double) -> Double { r.isInfinite ? hi : Swift.min(hi, Swift.max(lo, r)) }
        guard let first = points.first, let last = points.last else { return lo }
        if temperature <= first.temperature { return resolve(first.rpm) }
        if temperature >= last.temperature { return resolve(last.rpm) }
        for (a, b) in zip(points, points.dropFirst()) where temperature <= b.temperature {
            let ra = resolve(a.rpm), rb = resolve(b.rpm)
            let f = (temperature - a.temperature) / Swift.max(b.temperature - a.temperature, 0.0001)
            return ra + (rb - ra) * f
        }
        return resolve(last.rpm)
    }

    /// The editable representation preserves decimal values when a policy is loaded into the UI.
    public var pointsText: String {
        points.map { p in
            let r = p.rpm == .infinity ? "max" : (p.rpm == 0 ? "min" : fanNumber(p.rpm))
            return "\(fanNumber(p.temperature)):\(r)"
        }.joined(separator: ",")
    }

    public var description: String { pointsText + " (\(sensor.rawValue))" }

    public func validate() throws {
        guard !points.isEmpty else { throw FanControlError.badCurve("empty") }
        var previous = -Double.infinity
        for point in points {
            guard point.temperature.isFinite, point.temperature > previous,
                  point.rpm >= 0, point.rpm.isFinite || point.rpm == .infinity else {
                throw FanControlError.badCurve(pointsText)
            }
            previous = point.temperature
        }
    }

    public static let quiet = FanCurve(points: [.init(60, 0), .init(80, 3500), .init(92, .infinity)])
    public static let balanced = FanCurve(points: [.init(50, 0), .init(70, 3500), .init(85, .infinity)])
    public static let performance = FanCurve(points: [.init(40, 2500), .init(60, 4500), .init(75, .infinity)])
}

private func fanNumber(_ value: Double) -> String {
    let text = String(value)
    return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
}

public enum FanPolicy: Codable, Hashable, Sendable {
    case auto
    case fixed(rpm: Double)
    case curve(FanCurve)

    public func validate() throws {
        switch self {
        case .auto: break
        case .fixed(let rpm):
            guard rpm >= 0, rpm.isFinite || rpm == .infinity else { throw FanControlError.helper("invalid fan speed") }
        case .curve(let curve): try curve.validate()
        }
    }

    public var description: String {
        switch self {
        case .auto: return "auto"
        case .fixed(let r): return r.isInfinite ? "fixed max" : "fixed \(fanNumber(r)) rpm"
        case .curve(let c): return "curve \(c.description)"
        }
    }
}

public enum FanControlError: Error, CustomStringConvertible {
    case badCurve(String)
    case noSuchFan(Int)
    case helperUnavailable(String)
    case helper(String)

    public var description: String {
        switch self {
        case .badCurve(let s): return "invalid curve point '\(s)' (expected TEMP:RPM|min|max, e.g. 50:min,70:3000,85:max)"
        case .noSuchFan(let i): return "no fan with id \(i)"
        case .helperUnavailable(let s): return "helper unavailable: \(s)\nInstall it with: thermo helper install"
        case .helper(let s): return s
        }
    }
}

/// Performs SMC writes for fan control. Requires root (used by the helper).
public protocol FanSMCAccess: AnyObject {
    func double(_ key: FourCC) throws -> Double
    func write(_ key: FourCC, value: Double) throws
}

extension SMC: FanSMCAccess {}

public struct FanAutoRecoveryReport: Codable, Sendable, Equatable {
    public var unconfirmed: [String]
    public var requestErrors: [String]
    public init(unconfirmed: [String],requestErrors: [String]) { self.unconfirmed=unconfirmed;self.requestErrors=requestErrors }
    public var confirmed: Bool { unconfirmed.isEmpty }
    public var summary: String { confirmed ? "automatic control confirmed" : "automatic control unconfirmed: " + unconfirmed.joined(separator: "; ") }
}

public final class FanWriter {
    let smc: any FanSMCAccess
    let discovery: Discovery
    private var unlocked = false
    /// Intel: F<i>Md value seen before we touched anything, restored by setAuto.
    /// (Apple Silicon reports 3 while thermalmonitord is in charge but refuses a
    /// write of 3 — there auto is F<i>Md=0 followed by Ftst=0; see setAuto.)
    private var originalMode: [Int: Double] = [:]

    public init(smc: any FanSMCAccess, discovery: Discovery) {
        self.smc = smc
        self.discovery = discovery
        for f in discovery.fans where f.hasModeKey {
            if let m = try? smc.double(f.modeKey) {
                // Restore only known automatic states, never leftover manual or unknown modes.
                originalMode[f.index] = m == 3 ? 3 : 0
            }
        }
    }

    func fan(_ id: Int) throws -> FanDescriptor {
        guard let f = discovery.fans.first(where: { $0.index == id }) else { throw FanControlError.noSuchFan(id) }
        return f
    }

    public func limits(_ id: Int) throws -> (min: Double, max: Double) {
        let f = try fan(id)
        return (try smc.double(f.minKey), try smc.double(f.maxKey))
    }

    /// Put a fan in manual mode and set its target, clamped to the fan's range.
    @discardableResult
    public func setManual(_ id: Int, rpm: Double) throws -> Double {
        let f = try fan(id)
        let (lo, hi) = try limits(id)
        guard lo.isFinite, hi.isFinite, lo >= 0, hi > 0, lo <= hi,
              rpm >= 0, rpm.isFinite || rpm == .infinity else {
            throw FanControlError.helper("fan \(id): invalid speed or hardware limits")
        }
        guard f.hasModeKey || discovery.fanForceKey else {
            throw FanControlError.helper("fan \(id): no manual-control readback key")
        }
        let target = rpm.isInfinite ? hi : Swift.min(hi, Swift.max(lo, rpm))

        if discovery.fanTestKey && !unlocked {
            // Apple Silicon: thermalmonitord owns the fans until Ftst=1.
            try smc.write("Ftst", value: 1)
        }
        // Recheck ownership even when a previous write unlocked it: firmware may reclaim it.
        if discovery.fanTestKey {
            guard try smc.double("Ftst") == 1 else {
                unlocked = false
                throw FanControlError.helper("fan \(id): manual unlock readback did not match")
            }
            unlocked = true
        }
        return try retrying {
            if f.hasModeKey {
                try smc.write(f.modeKey, value: 1)
            } else if discovery.fanForceKey {
                let bits = try forceBits(fan: id)
                try smc.write("FS! ", value: Double(bits | (1 << id)))
            }
            try smc.write(f.targetKey, value: target)
            return try verifyManual(id, rpm: target)
        }
    }

    /// Check an unchanged target without rewriting it; firmware can reclaim control
    /// between helper ticks, including while hysteresis suppresses further writes.
    @discardableResult
    public func verifyManual(_ id: Int, rpm target: Double) throws -> Double {
        let f = try fan(id)
        guard target.isFinite, target >= 0 else { throw FanControlError.helper("fan \(id): invalid target") }
        if discovery.fanTestKey {
            guard try smc.double("Ftst") == 1 else {
                unlocked = false
                throw FanControlError.helper("fan \(id): manual unlock readback did not match")
            }
        }
        if f.hasModeKey {
            let mode = try smc.double(f.modeKey)
            guard mode == 1 else {
                throw FanControlError.helper("fan \(id): manual mode readback did not match (expected 1, observed \(mode))")
            }
        } else if discovery.fanForceKey {
            guard try forceBits(fan: id) & (1 << id) != 0 else {
                throw FanControlError.helper("fan \(id): manual force bit did not match")
            }
        } else { throw FanControlError.helper("fan \(id): no manual-control readback key") }
        let actual = try smc.double(f.targetKey)
        // Integer, fpe2 and Float targets quantize differently. One RPM covers the
        // representable rounding; this is target-register confirmation, not rotor speed.
        guard actual.isFinite, abs(actual - target) <= 1 else {
            throw FanControlError.helper("fan \(id): target speed readback did not match")
        }
        return actual
    }

    public func setAuto(_ id: Int) throws {
        let f = try fan(id)
        var failures: [String] = []
        if f.hasModeKey {
            // Apple Silicon: 0 hands the fan back; thermalmonitord sets its own mode
            // once Ftst is cleared (setAllAuto / the last fan going auto).
            let mode = discovery.fanTestKey ? 0 : (originalMode[id] ?? 0)
            do { try smc.write(f.modeKey, value: mode) } catch { failures.append(String(describing: error)) }
        }
        if discovery.fanForceKey {
            do {
                let bits = try forceBits(fan: id)
                try smc.write("FS! ", value: Double(bits & ~(1 << id)))
            } catch { failures.append(String(describing: error)) }
        }
        do { try verifyAuto(f) } catch { failures.append(String(describing: error)) }
        if discovery.fanTestKey && unlocked && discovery.fans.allSatisfy({ fan in
            do { try verifyAuto(fan); return true } catch { return false }
        }) {
            do {
                try smc.write("Ftst", value: 0)
                guard try smc.double("Ftst") == 0 else { throw FanControlError.helper("Ftst unlock remains active") }
                unlocked = false
                for fan in discovery.fans { try verifyAuto(fan) }
            } catch { failures.append(String(describing: error)) }
        }
        if !failures.isEmpty { throw FanControlError.helper(failures.joined(separator: "; ")) }
    }

    private func verifyAuto(_ f: FanDescriptor) throws {
        if f.hasModeKey {
            let value = try smc.double(f.modeKey)
            let valid = value == 0 || value == 3
            guard valid else { throw FanControlError.helper("fan \(f.index): automatic mode readback did not match") }
        }
        if discovery.fanForceKey {
            guard try forceBits(fan: f.index) & (1 << f.index) == 0 else {
                throw FanControlError.helper("fan \(f.index): force bit still set or unavailable")
            }
        }
        if !f.hasModeKey && !discovery.fanForceKey { throw FanControlError.helper("fan \(f.index): no automatic-control readback key") }
    }

    private func forceBits(fan: Int) throws -> Int {
        let value = try smc.double("FS! ")
        guard (0..<16).contains(fan), value.isFinite, value >= 0, value <= 65535, value.rounded() == value else {
            throw FanControlError.helper("fan \(fan): invalid force-bitfield readback")
        }
        return Int(value)
    }

    /// Attempt every reset, then independently read back the resulting state. A successful
    /// write is not confirmation; a failed request may still be recovered by clearing Ftst.
    @discardableResult
    public func setAllAuto() -> FanAutoRecoveryReport {
        var requests: [String] = [], unconfirmed: [String] = []
        for f in discovery.fans {
            do { try setAuto(f.index) } catch { requests.append(String(describing: error)) }
        }
        if discovery.fanTestKey {
            do { try smc.write("Ftst", value: 0) } catch { requests.append(String(describing: error)) }
            unlocked = false
            do {
                guard try smc.double("Ftst") == 0 else { throw FanControlError.helper("Ftst unlock remains active") }
            } catch { unconfirmed.append(String(describing: error)) }
        }
        for f in discovery.fans {
            do { try verifyAuto(f) } catch { unconfirmed.append(String(describing: error)) }
        }
        return FanAutoRecoveryReport(unconfirmed: unconfirmed, requestErrors: requests)
    }

    /// A successful write can precede its mode/target readback. Retry the bounded
    /// transition as a whole; an unchanged-target verification never writes.
    private func retrying<T>(_ body: () throws -> T) throws -> T {
        var last: Error?
        // Measured on an M4 Pro: the first F0Md write after Ftst=1 can be refused
        // for a little over 2 s, so allow up to 5 s before reporting failure.
        for attempt in 0..<50 {
            do { return try body() } catch { last = error }
            if attempt == 49 { break }
            usleep(100_000)
        }
        throw last!
    }
}

/// Holds per-fan policies and decides what to write on each tick. Pure logic, no I/O.
/// Over-temperature safety limits. Measured 2026-10-10: an M4 under a heavy build,
/// with macOS controlling its own fan, keeps P-core sensors at 103–115 °C (the chip
/// throttles itself), so a 95 °C ceiling there fired constantly. Intel parts sit
/// below their 100 °C Tjmax, so 95 °C stays right for them.
public struct SafetyLimits: Equatable, Sendable {
    /// Hottest CPU/GPU sensor at or above this, sustained, suspends every policy.
    public var ceiling: Double
    /// Policies resume once the hottest sensor stays below this...
    public var resumeBelow: Double
    /// ...for this many consecutive ticks (helper tick = 2 s).
    public var resumeTicks: Int
    /// Consecutive hot ticks needed to trip (a single spike is ignored).
    public var triggerTicks: Int

    public static let intel = SafetyLimits(ceiling: 95, resumeBelow: 85, resumeTicks: 30, triggerTicks: 2)
    public static let appleSilicon = SafetyLimits(ceiling: 110, resumeBelow: 100, resumeTicks: 30, triggerTicks: 2)

    public static func forHardware(appleSilicon: Bool) -> SafetyLimits { appleSilicon ? .appleSilicon : .intel }
}

public enum FanPolicySuspension: String, Codable, Sendable { case thermal, temperatureUnavailable }

/// Pure control decisions. Unsafe policies wait for valid cooling telemetry after
/// heat or sensor loss; the user's desired policies are retained.
public struct FanPolicyEngine: Sendable {
    public private(set) var policies: [Int: FanPolicy] = [:]
    public let limits: SafetyLimits
    /// Over-temperature: fans are on system control until it cools down.
    public private(set) var suspended = false
    public private(set) var suspensionReason: FanPolicySuspension?
    private var hotTicks = 0
    private var coolTicks = 0
    private var requiresGPU: Bool

    public init(limits: SafetyLimits = .intel, requiresGPU: Bool = false) {
        self.limits = limits
        self.requiresGPU = requiresGPU
    }

    public var isActive: Bool { policies.values.contains { $0 != .auto } }

    public mutating func set(_ policy: FanPolicy, for fan: Int) {
        if policy == .auto { policies.removeValue(forKey: fan) } else { policies[fan] = policy }
        if !isActive { resetSafety() }
    }

    public mutating func clear() {
        policies.removeAll()
        resetSafety()
    }

    private mutating func resetSafety() {
        suspended = false
        suspensionReason = nil
        hotTicks = 0
        coolTicks = 0
    }

    public enum Action: Equatable {
        case manual(fan: Int, rpm: Double)
        case auto(fan: Int)
        /// Over-temperature: every fan to system control; policies kept but suspended.
        case failsafe(temperature: Double)
        /// Required CPU temperature is unavailable; under-cooling policies must wait.
        case temperatureUnavailable
        /// Cooled down after a failsafe: policies apply again (manual actions follow).
        case resume(temperature: Double)
    }

    /// Share telemetry coverage with the lid-awake guard, even without fan policies.
    public mutating func observeControlTemperature(_ s: Snapshot) -> Double? {
        let gpu = s.controlTemperature(for: .gpu)
        if gpu != nil { requiresGPU = true }
        return requiresGPU && gpu == nil ? nil : s.controlTemperature()
    }

    public mutating func tick(_ s: Snapshot) -> [Action] {
        guard isActive else { return [] }
        let temperature = observeControlTemperature(s)
        // Fans asked to run flat out cool better than system control ever would, so the
        // failsafe leaves them alone; only policies that could under-cool are suspended.
        let fullCooling = fullCoolingActions(s)
        if fullCooling.count == policies.count && fullCooling.allSatisfy({ if case .manual = $0 { return true }; return false }) {
            resetSafety(); return temperature == nil ? fullCooling : policyActions(s)
        }

        guard let hot = temperature else {
            hotTicks = 0; coolTicks = 0
            let newlyMissing = suspensionReason != .temperatureUnavailable
            suspended = true; suspensionReason = .temperatureUnavailable
            return (newlyMissing ? [.temperatureUnavailable] : []) + fullCooling
        }

        if suspended {
            if suspensionReason == .temperatureUnavailable && hot >= limits.ceiling {
                suspensionReason = .thermal
                return [.failsafe(temperature: hot)] + fullCooling
            }
            coolTicks = hot < limits.resumeBelow ? coolTicks + 1 : 0
            guard coolTicks >= limits.resumeTicks else { return fullCooling }
            resetSafety()
            return [.resume(temperature: hot)] + policyActions(s)
        }

        hotTicks = hot >= limits.ceiling ? hotTicks + 1 : 0
        if hotTicks >= limits.triggerTicks {
            suspended = true
            suspensionReason = .thermal
            hotTicks = 0
            coolTicks = 0
            return [.failsafe(temperature: hot)] + fullCooling
        }
        return policyActions(s)
    }

    /// A fixed speed at (or within 5 % of) the fan's maximum.
    static func isFullCooling(_ p: FanPolicy, max: Double) -> Bool {
        if case .fixed(let rpm) = p { return rpm.isInfinite || rpm >= max * 0.95 }
        return false
    }

    private func fullCoolingActions(_ s: Snapshot) -> [Action] {
        s.fans.compactMap { fan in
            guard let p = policies[fan.id] else { return nil }
            guard let range = fan.validRange else { return .auto(fan: fan.id) }
            guard Self.isFullCooling(p, max: range.max) else { return nil }
            return .manual(fan: fan.id, rpm: range.max)
        }
    }

    private func policyActions(_ s: Snapshot) -> [Action] {
        var actions: [Action] = []
        for fan in s.fans {
            guard let range = fan.validRange else {
                if policies[fan.id] != nil { actions.append(.auto(fan: fan.id)) }
                continue
            }
            switch policies[fan.id] ?? .auto {
            case .auto:
                continue
            case .fixed(let rpm):
                actions.append(.manual(fan: fan.id, rpm: rpm.isInfinite ? range.max : Swift.min(range.max, Swift.max(range.min, rpm))))
            case .curve(let c):
                guard let t = s.controlTemperature(for: c.sensor) else { actions.append(.auto(fan: fan.id)); continue }
                actions.append(.manual(fan: fan.id, rpm: c.rpm(at: t, min: range.min, max: range.max)))
            }
        }
        return actions
    }
}
