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
        func int(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
        func bool(_ k: String) -> Bool { (d[k] as? NSNumber)?.boolValue ?? false }

        // CurrentCapacity/MaxCapacity are percentages on modern macOS; raw values are mAh.
        var percent: Double?
        if let cur = int("CurrentCapacity"), let max = int("MaxCapacity"), max > 0 {
            percent = Double(cur) / Double(max) * 100
        }
        var health: Double?
        if let raw = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity"),
           let design = int("DesignCapacity"), design > 0 {
            health = Double(raw) / Double(design)
        }
        // Amperage is a signed 64-bit value that some releases expose as unsigned.
        var amps: Double?
        if let n = d["Amperage"] as? NSNumber { amps = Double(Int64(truncatingIfNeeded: n.int64Value)) / 1000 }

        return BatteryInfo(
            percent: percent,
            temperature: int("Temperature").map { Double($0) / 100 },
            voltage: int("Voltage").map { Double($0) / 1000 },
            amperage: amps,
            cycleCount: int("CycleCount"),
            health: health,
            charging: bool("IsCharging"),
            externalPower: bool("ExternalConnected")
        )
    }
}
