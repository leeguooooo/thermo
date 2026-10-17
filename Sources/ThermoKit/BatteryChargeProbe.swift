import Foundation

public enum BatteryPresence: String, Codable, Sendable { case present, notObserved, unknown }
public enum BatteryChargeSupport: String, Codable, Sendable { case smc, systemSettings, unsupported, noInternalBattery, unknown }

public struct BatteryChargeProbe: Encodable, Sendable {
    public struct Register: Codable, Sendable {
        public let key: FourCC
        public var info: SMCKeyInfo?
        public var hex: String?
        public var error: String?
    }
    public var presence: BatteryPresence
    public var support: BatteryChargeSupport
    public var availability: BatteryGateAvailability
    public var gate: BatteryChargePolicy.Gate
    public var registers: [Register]
    public var error: String?
    public let changesMade = false
    public let sessionStateQueried = false

    public static func support(presence: BatteryPresence, availability: BatteryGateAvailability, nativeEligible: Bool) -> BatteryChargeSupport {
        switch presence {
        case .notObserved: return .noInternalBattery
        case .unknown: return .unknown
        case .present:
            switch availability {
            case .available: return .smc
            case .unsupported: return nativeEligible ? .systemSettings : .unsupported
            case .unavailable: return .unknown
            }
        }
    }
    /// Uses only info/read. No recovery store, hardware UUID or helper connection.
    public static func capture(io: BatteryGateIO, presence: BatteryPresence, nativeEligible: Bool) -> Self {
        var rows: [Register] = []
        for key: FourCC in ["CH0B", "CH0C", "CHTE"] {
            var row = Register(key: key)
            do {
                row.info = try io.info(key)
                if row.info != nil { row.hex = try io.read(key).hex }
            } catch { row.error = error.localizedDescription }
            rows.append(row)
        }
        var gate: BatteryChargePolicy.Gate = .unknown, availability: BatteryGateAvailability = .unavailable, issue: String?
        do {
            let (layout, infos) = try BatteryGateLayout.detect(io)
            availability = .available
            let bytes = try infos.map { info -> [UInt8] in
                guard try io.info(info.key) == info else { throw BatteryGateError("Charging metadata changed during probe") }
                let value = try io.read(info.key)
                guard value.key == info.key, value.type == info.type, value.bytes.count == info.size else { throw BatteryGateError("Charging register read is incomplete") }
                return value.bytes
            }
            if bytes.allSatisfy({ $0 == layout.enabled }) { gate = .allowed }
            else if bytes.allSatisfy({ $0 == layout.inhibited }) { gate = .inhibited }
            else { issue = "Unknown or inconsistent charging register values" }
        } catch let error as BatteryGateError where error.category == .unsupported { availability = .unsupported; issue = error.localizedDescription }
        catch { issue = error.localizedDescription }
        return .init(presence: presence, support: support(presence: presence, availability: availability, nativeEligible: nativeEligible), availability: availability,
                     gate: gate, registers: rows, error: issue)
    }
    public static func live() -> Self {
        let presence = BatteryChargeSystem.presence(), native = BatteryChargeSystem.nativeLimitEligible
        do { return capture(io: .system(try SMC()), presence: presence, nativeEligible: native) }
        catch { return .init(presence: presence, support: support(presence: presence, availability: .unavailable, nativeEligible: native), availability: .unavailable, gate: .unknown, registers: [], error: error.localizedDescription) }
    }
}
