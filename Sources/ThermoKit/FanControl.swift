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
        rpm = r < 0 ? .infinity : r
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
        for part in text.split(separator: ",") {
            let kv = part.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let t = Double(kv[0].replacingOccurrences(of: "°", with: "").replacingOccurrences(of: "C", with: "")) else {
                throw FanControlError.badCurve(String(part))
            }
            let rpm: Double
            switch kv[1].lowercased() {
            case "max": rpm = .infinity
            case "min": rpm = 0
            default:
                guard let r = Double(kv[1]), r >= 0 else { throw FanControlError.badCurve(String(part)) }
                rpm = r
            }
            pts.append(CurvePoint(t, rpm))
        }
        guard !pts.isEmpty else { throw FanControlError.badCurve(text) }
        self.init(points: pts, sensor: sensor)
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

    public var description: String {
        points.map { p in
            let r = p.rpm.isInfinite ? "max" : (p.rpm == 0 ? "min" : String(Int(p.rpm)))
            return "\(Int(p.temperature)):\(r)"
        }.joined(separator: ",") + " (\(sensor.rawValue))"
    }

    public static let quiet = FanCurve(points: [.init(60, 0), .init(80, 3500), .init(92, .infinity)])
    public static let balanced = FanCurve(points: [.init(50, 0), .init(70, 3500), .init(85, .infinity)])
    public static let performance = FanCurve(points: [.init(40, 2500), .init(60, 4500), .init(75, .infinity)])
}

public enum FanPolicy: Codable, Hashable, Sendable {
    case auto
    case fixed(rpm: Double)
    case curve(FanCurve)

    public var description: String {
        switch self {
        case .auto: return "auto"
        case .fixed(let r): return r.isInfinite ? "fixed max" : "fixed \(Int(r)) rpm"
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

    public init(smc: SMC, discovery: Discovery) {
        self.smc = smc
        self.discovery = discovery
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
            try smc.write(f.modeKey, value: 0)
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
        for attempt in 0..<20 {
            do { try body(); return } catch { last = error }
            if !discovery.fanTestKey || attempt == 19 { break }
            usleep(100_000)
        }
        throw last!
    }
}

/// Holds per-fan policies and decides what to write on each tick. Pure logic, no I/O.
public struct FanPolicyEngine: Sendable {
    public static let safetyCeiling = 95.0

    public private(set) var policies: [Int: FanPolicy] = [:]

    public init() {}

    public var isActive: Bool { policies.values.contains { $0 != .auto } }

    public mutating func set(_ policy: FanPolicy, for fan: Int) {
        if policy == .auto { policies.removeValue(forKey: fan) } else { policies[fan] = policy }
    }

    public mutating func clear() { policies.removeAll() }

    public enum Action: Equatable {
        case manual(fan: Int, rpm: Double)
        case auto(fan: Int)
        /// Over-temperature: everything to auto, policies cleared.
        case failsafe(temperature: Double)
    }

    public mutating func tick(_ s: Snapshot) -> [Action] {
        guard isActive else { return [] }
        if let hot = s.hottest, hot >= Self.safetyCeiling {
            clear()
            return [.failsafe(temperature: hot)]
        }
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
