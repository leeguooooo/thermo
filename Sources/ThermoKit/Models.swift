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
    public let rpm: Double
    public let min: Double
    public let max: Double
    public let target: Double?
    public let manual: Bool

    /// 0...1 position between min and max.
    public var load: Double {
        guard max > min else { return 0 }
        return Swift.min(1, Swift.max(0, (rpm - min) / (max - min)))
    }
}

public struct BatteryInfo: Codable, Hashable, Sendable {
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
    public let timestamp: Date
    public let temperatures: [Reading]
    public let fans: [FanReading]
    public let power: [Reading]
    public let voltages: [Reading]
    public let currents: [Reading]
    public let battery: BatteryInfo?

    public init(timestamp: Date = Date(), temperatures: [Reading], fans: [FanReading], power: [Reading],
                voltages: [Reading], currents: [Reading], battery: BatteryInfo?) {
        self.timestamp = timestamp; self.temperatures = temperatures; self.fans = fans; self.power = power
        self.voltages = voltages; self.currents = currents; self.battery = battery
    }

    public func maxTemperature(in group: SensorGroup) -> Double? {
        temperatures.lazy.filter { $0.group == group && $0.known }.map(\.value).max()
    }

    public func averageTemperature(in group: SensorGroup) -> Double? {
        let v = temperatures.filter { $0.group == group && $0.known }.map(\.value)
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    public var cpu: Double? { maxTemperature(in: .cpu) }
    public var gpu: Double? { maxTemperature(in: .gpu) }

    /// Hottest compute sensor (CPU or GPU); falls back to any known sensor.
    public var hottest: Double? {
        [cpu, gpu].compactMap { $0 }.max() ?? temperatures.filter(\.known).map(\.value).max()
    }

    public func temperature(for sensor: CurveSensor) -> Double? {
        switch sensor {
        case .cpu: return cpu ?? hottest
        case .gpu: return gpu ?? hottest
        case .max: return hottest
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
