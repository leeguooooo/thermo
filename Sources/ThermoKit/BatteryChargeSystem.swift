import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Live wiring is used only by the installed root helper, never by mock tests.
public enum BatteryChargeSystem {
    public static func presence() -> BatteryPresence {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [AnyObject] else { return .unknown }
        let types = list.map { source -> String? in
            guard let dict = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { return nil }
            return dict[kIOPSTypeKey] as? String
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        let registryBatteryPresent = service != 0
        if service != 0 { IOObjectRelease(service) }
        return presence(sourceTypes: types, registryBatteryPresent: registryBatteryPresent)
    }
    static func presence(sourceTypes: [String?], registryBatteryPresent: Bool = false) -> BatteryPresence {
        if sourceTypes.contains(where: { $0 == kIOPSInternalBatteryType }) { return .present }
        if registryBatteryPresent { return .unknown } // Conflicting observations cannot establish absence.
        return sourceTypes.allSatisfy({ $0 == kIOPSUPSType }) ? .notObserved : .unknown
    }
    public static func nativeLimitEligible(major: Int, minor: Int, appleSilicon: Bool) -> Bool {
        appleSilicon && (major > 26 || (major == 26 && minor >= 4))
    }
    public static var nativeLimitEligible: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return nativeLimitEligible(major: version.majorVersion, minor: version.minorVersion, appleSilicon: LidAwakeController.appleSilicon)
    }
    public static func hardwareID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }; defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { return nil }
        return UUID(uuidString: value)?.uuidString
    }
    public static func power() -> BatteryChargePolicy.Observation? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }; defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return parsePower(dict, now: AWDLSystemClock.now())
    }
    static func parsePower(_ dict: [String: Any], now: TimeInterval) -> BatteryChargePolicy.Observation {
        let raw = dict["ExternalConnected"] as? NSNumber
        let external = raw.flatMap { $0.doubleValue == 0 ? false : $0.doubleValue == 1 ? true : nil }
        return .init(percent: Battery.parse(dict).percent, externalPower: external, observedAt: now)
    }
    private static func prepareDirectory() throws {
        guard geteuid() == 0 else { throw BatteryGateError("Charging control requires the root helper") }
        let parent = open("/Library/Application Support", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard parent >= 0 else { throw BatteryGateError("Charging recovery parent is unavailable") }; defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0 else { throw BatteryGateError("Charging recovery parent is unsafe") }
        guard mkdirat(parent, "dev.thermo", 0o700) == 0 || errno == EEXIST else { throw BatteryGateError("Cannot create charging recovery directory") }
        guard fsync(parent) == 0 else { throw BatteryGateError("Cannot sync charging recovery directory") }
        // The lease store reopens and validates the final directory without following links.
    }
    public static func make() throws -> BatteryChargingGate {
        try prepareDirectory()
        return BatteryChargingGate(io: .system(try SMC()), store: BatteryGateLeaseFile().io, hardwareID: hardwareID)
    }
}
