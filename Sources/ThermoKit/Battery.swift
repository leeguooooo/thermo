import Foundation
import IOKit

/// Reads the AppleSmartBattery registry entry (no SMC needed, no root needed).
public enum Battery {
    public static func read() -> BatteryInfo? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return parse(dict)
    }

    static func parse(_ d: [String: Any]) -> BatteryInfo {
        // Newer macOS (Apple Silicon) moves capacities into the BatteryData sub-dictionary.
        let nested = d["BatteryData"] as? [String: Any] ?? [:]
        func number(_ key: String) -> NSNumber? {
            for value in [d[key], nested[key]] {
                if let number = value as? NSNumber, number.doubleValue.isFinite { return number }
            }
            return nil
        }
        func int(_ key: String) -> Int? {
            guard let number = number(key), number.doubleValue >= Double(Int.min),
                  number.doubleValue <= Double(Int.max) else { return nil }
            return number.intValue
        }
        func nonnegative(_ key: String) -> Int? { int(key).flatMap { $0 >= 0 ? $0 : nil } }
        func bool(_ key: String) -> Bool { number(key)?.boolValue ?? false }

        // CurrentCapacity/MaxCapacity are percentages on modern macOS; raw values are mAh.
        var percent: Double?
        if let cur = nonnegative("CurrentCapacity"), let max = int("MaxCapacity"), max > 0 {
            percent = min(100, Double(cur) / Double(max) * 100)
        }
        var health: Double?
        if let raw = nonnegative("AppleRawMaxCapacity") ?? nonnegative("NominalChargeCapacity") ?? nonnegative("FullChargeCapacity"),
           let design = int("DesignCapacity"), design > 0 {
            health = min(1, Double(raw) / Double(design))   // fresh batteries can exceed design
        }
        // Amperage is a signed 64-bit value that some releases expose as unsigned.
        var amps: Double?
        if let n = number("Amperage") { amps = Double(Int64(truncatingIfNeeded: n.int64Value)) / 1000 }

        return BatteryInfo(
            percent: percent,
            temperature: nonnegative("Temperature").map { Double($0) / 100 },
            voltage: int("Voltage").flatMap { $0 > 0 ? Double($0) / 1000 : nil },
            amperage: amps,
            cycleCount: nonnegative("CycleCount"),
            health: health,
            charging: bool("IsCharging"),
            externalPower: bool("ExternalConnected")
        )
    }
}
