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
public final class FanWriter {
    let smc: SMC
    let discovery: Discovery
    private var unlocked = false
    /// Intel: F<i>Md value seen before we touched anything, restored by setAuto.
    /// (Apple Silicon reports 3 while thermalmonitord is in charge but refuses a
    /// write of 3 — there auto is F<i>Md=0 followed by Ftst=0; see setAuto.)
    private var originalMode: [Int: Double] = [:]

    public init(smc: SMC, discovery: Discovery) {
        self.smc = smc
        self.discovery = discovery
        for f in discovery.fans where f.hasModeKey {
            if let m = try? smc.double(f.modeKey) {
                // A leftover manual mode (e.g. after a crash) is not worth restoring.
                originalMode[f.index] = m == 1 ? 0 : m
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
        let target = rpm.isInfinite ? hi : Swift.min(hi, Swift.max(lo, rpm))

        if discovery.fanTestKey && !unlocked {
            // Apple Silicon: thermalmonitord owns the fans until Ftst=1.
            try smc.write("Ftst", value: 1)
            unlocked = true
        }
        if f.hasModeKey {
            try retrying { try smc.write(f.modeKey, value: 1) }
        } else if discovery.fanForceKey {
            let bits = Int(try smc.double("FS! "))
            try smc.write("FS! ", value: Double(bits | (1 << id)))
        }
        try smc.write(f.targetKey, value: target)
        return target
    }

    public func setAuto(_ id: Int) throws {
        let f = try fan(id)
        if f.hasModeKey {
            // Apple Silicon: 0 hands the fan back; thermalmonitord sets its own mode
            // once Ftst is cleared (setAllAuto / the last fan going auto).
            let mode = discovery.fanTestKey ? 0 : (originalMode[id] ?? 0)
            try smc.write(f.modeKey, value: mode)
        } else if discovery.fanForceKey {
            let bits = Int(try smc.double("FS! "))
            try smc.write("FS! ", value: Double(bits & ~(1 << id)))
        }
    }

    /// Best-effort: every fan back to firmware control.
    public func setAllAuto() {
        for f in discovery.fans { try? setAuto(f.index) }
        if discovery.fanTestKey {
            try? smc.write("Ftst", value: 0)
            unlocked = false
        }
    }

    /// Mode writes can be refused for a moment right after the Ftst unlock.
    private func retrying(_ body: () throws -> Void) throws {
        var last: Error?
        // Measured on an M4 Pro: the first F0Md write after Ftst=1 can be refused
        // for a little over 2 s, so allow up to 5 s before reporting failure.
        for attempt in 0..<50 {
            do { try body(); return } catch { last = error }
            if !discovery.fanTestKey || attempt == 49 { break }
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

/// Holds per-fan policies and decides what to write on each tick. Pure logic, no I/O.
///
/// When the machine runs hot under a policy, the fans go back to system control
/// and the policies are *suspended*, not lost: they resume once it has cooled.
public struct FanPolicyEngine: Sendable {
    public private(set) var policies: [Int: FanPolicy] = [:]
    public let limits: SafetyLimits
    /// Over-temperature: fans are on system control until it cools down.
    public private(set) var suspended = false
    private var hotTicks = 0
    private var coolTicks = 0

    public init(limits: SafetyLimits = .intel) {
        self.limits = limits
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
        hotTicks = 0
        coolTicks = 0
    }

    public enum Action: Equatable {
        case manual(fan: Int, rpm: Double)
        case auto(fan: Int)
        /// Over-temperature: every fan to system control; policies kept but suspended.
        case failsafe(temperature: Double)
        /// Cooled down after a failsafe: policies apply again (manual actions follow).
        case resume(temperature: Double)
    }

    public mutating func tick(_ s: Snapshot) -> [Action] {
        guard isActive else { return [] }
        let hot = s.hottest ?? 0
        // Fans asked to run flat out cool better than system control ever would, so the
        // failsafe leaves them alone; only policies that could under-cool are suspended.
        let fullCooling = fullCoolingActions(s)
        if fullCooling.count == policies.count { resetSafety(); return policyActions(s) }

        if suspended {
            coolTicks = hot < limits.resumeBelow ? coolTicks + 1 : 0
            guard coolTicks >= limits.resumeTicks else { return fullCooling }
            resetSafety()
            return [.resume(temperature: hot)] + policyActions(s)
        }

        hotTicks = hot >= limits.ceiling ? hotTicks + 1 : 0
        if hotTicks >= limits.triggerTicks {
            suspended = true
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
            guard let p = policies[fan.id], Self.isFullCooling(p, max: fan.max) else { return nil }
            return .manual(fan: fan.id, rpm: fan.max)
        }
    }

    private func policyActions(_ s: Snapshot) -> [Action] {
        var actions: [Action] = []
        for fan in s.fans {
            switch policies[fan.id] ?? .auto {
            case .auto:
                continue
            case .fixed(let rpm):
                actions.append(.manual(fan: fan.id, rpm: rpm.isInfinite ? fan.max : Swift.min(fan.max, Swift.max(fan.min, rpm))))
            case .curve(let c):
                guard let t = s.temperature(for: c.sensor) else { actions.append(.auto(fan: fan.id)); continue }
                actions.append(.manual(fan: fan.id, rpm: c.rpm(at: t, min: fan.min, max: fan.max)))
            }
        }
        return actions
    }
}
