import Foundation

public enum SensorGroup: String, Codable, CaseIterable, Sendable {
    case cpu = "CPU"
    case gpu = "GPU"
    case memory = "Memory"
    case storage = "Storage"
    case battery = "Battery"
    case ambient = "Ambient"
    case board = "Board"
    case other = "Other"
}

public enum Quantity: String, Codable, Sendable {
    case temperature, power, voltage, current

    public var unit: String {
        switch self {
        case .temperature: return "°C"
        case .power: return "W"
        case .voltage: return "V"
        case .current: return "A"
        }
    }
}

/// A single sensor value.
public struct Reading: Codable, Hashable, Sendable, Identifiable {
    /// SMC key ("TC0P") or "hid:<name>" for IOHID sensors.
    public let key: String
    public let name: String
    public let group: SensorGroup
    public let value: Double
    /// False for sensors without a curated name (shown only with --all).
    public let known: Bool

    public var id: String { key }

    public init(key: String, name: String, group: SensorGroup, value: Double, known: Bool = true) {
        self.key = key; self.name = name; self.group = group; self.value = value; self.known = known
    }
}

public struct FanReading: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let rpm: Double?
    public let min: Double?
    public let max: Double?
    public let target: Double?
    /// nil when control mode could not be established; never inferred as automatic.
    public let manual: Bool?
    public var controlMode: String { manual.map { $0 ? "manual" : "auto" } ?? "unknown" }

    enum CodingKeys: String, CodingKey { case id, name, rpm, min, max, target, manual }
    public init(id: Int, name: String, rpm: Double?, min: Double?, max: Double?, target: Double?, manual: Bool?) {
        self.id = id; self.name = name; self.manual = manual
        func valid(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        self.rpm = valid(rpm); self.target = valid(target)
        let lo = valid(min), hi = valid(max).flatMap { $0 > 0 ? $0 : nil }
        if let lo, let hi, lo > hi { self.min = nil; self.max = nil }
        else { self.min = lo; self.max = hi }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(Int.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                  rpm: try c.decodeIfPresent(Double.self, forKey: .rpm), min: try c.decodeIfPresent(Double.self, forKey: .min),
                  max: try c.decodeIfPresent(Double.self, forKey: .max), target: try c.decodeIfPresent(Double.self, forKey: .target),
                  manual: try c.decodeIfPresent(Bool.self, forKey: .manual))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(rpm, forKey: .rpm); try c.encode(min, forKey: .min); try c.encode(max, forKey: .max)
        try c.encodeIfPresent(target, forKey: .target)
        try c.encode(manual, forKey: .manual)
    }

    /// 0...1 position between min and max.
    public var validRange: (min: Double, max: Double)? {
        guard let min, let max, min <= max else { return nil }
        return (min, max)
    }
    public var load: Double? {
        guard let rpm, let range = validRange, range.max > range.min else { return nil }
        return Swift.min(1, Swift.max(0, (rpm - range.min) / (range.max - range.min)))
    }
}

public struct BatteryInfo: Codable, Hashable, Sendable {
    func with(temperature t: Double?) -> BatteryInfo {
        BatteryInfo(percent: percent, temperature: t, voltage: voltage, amperage: amperage, cycleCount: cycleCount,
                    health: health, charging: charging, externalPower: externalPower)
    }

    public let percent: Double?
    public let temperature: Double?
    public let voltage: Double?
    /// Amps; negative while discharging.
    public let amperage: Double?
    public let cycleCount: Int?
    /// Full-charge capacity / design capacity, 0...1.
    public let health: Double?
    public let charging: Bool
    public let externalPower: Bool

    /// Watts flowing into (+) or out of (−) the battery.
    public var power: Double? {
        guard let v = voltage, let a = amperage else { return nil }
        return v * a
    }
}

public struct Snapshot: Codable, Sendable {
    /// true: fan inventory known; false: discovery failed; nil: not sampled or legacy unknown.
    public let fansAvailable: Bool?
    public var hasFanReadings: Bool { fansAvailable ?? !fans.isEmpty }
    public let timestamp: Date
    public let temperatures: [Reading]
    public let fans: [FanReading]
    public let power: [Reading]
    public let voltages: [Reading]
    public let currents: [Reading]
    public let battery: BatteryInfo?

    public init(timestamp: Date = Date(), temperatures: [Reading], fans: [FanReading], power: [Reading],
                voltages: [Reading], currents: [Reading], battery: BatteryInfo?, fansAvailable: Bool? = nil) {
        self.timestamp = timestamp; self.temperatures = temperatures; self.fans = fans; self.power = power
        self.voltages = voltages; self.currents = currents; self.battery = battery; self.fansAvailable = fansAvailable
    }

    public func maxTemperature(in group: SensorGroup) -> Double? {
        temperatures.lazy.filter { $0.group == group && $0.known && $0.value.isFinite }.map(\.value).max()
    }

    public func averageTemperature(in group: SensorGroup) -> Double? {
        let v = temperatures.filter { $0.group == group && $0.known && $0.value.isFinite }.map(\.value)
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    public var cpu: Double? { maxTemperature(in: .cpu) }
    public var gpu: Double? { maxTemperature(in: .gpu) }

    /// Highest valid named reading across every sensor group, for display and alerts.
    public var maximumKnownTemperature: Double? {
        temperatures.lazy.filter { $0.known && $0.value.isFinite }.map(\.value).max()
    }

    /// Hottest compute sensor (CPU or GPU); falls back to any known sensor.
    public var hottest: Double? {
        [cpu, gpu].compactMap { $0 }.max() ?? maximumKnownTemperature
    }

    public func temperature(for sensor: CurveSensor) -> Double? {
        switch sensor {
        case .cpu: return cpu ?? hottest
        case .gpu: return gpu ?? hottest
        case .max: return hottest
        }
    }

    /// Control must never substitute a battery/board reading for CPU telemetry.
    /// A selected curve sensor must also supply its own valid positive reading.
    public func controlTemperature(for sensor: CurveSensor = .max) -> Double? {
        func valid(_ group: SensorGroup) -> Double? {
            temperatures.lazy.filter { $0.group == group && $0.known && $0.value.isFinite && $0.value > 0 }.map(\.value).max()
        }
        switch sensor {
        case .cpu: return valid(.cpu)
        case .gpu: return valid(.gpu)
        case .max:
            guard let cpu = valid(.cpu) else { return nil }
            return Swift.max(cpu, valid(.gpu) ?? cpu)
        }
    }

    /// Whole-system draw in watts, best available source.
    public var systemPower: Double? {
        power.first { $0.key == "PSTR" }?.value ?? power.first { $0.key == "PDTR" }?.value
    }

    public var cpuPower: Double? {
        power.first { $0.key == "PCPC" }?.value ?? power.first { $0.key == "PCPT" }?.value
            ?? power.first { $0.key == "PC0R" }?.value
    }
}
