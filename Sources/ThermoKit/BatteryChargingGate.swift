import Foundation

public enum BatteryChargeClientError: LocalizedError {
    case notStarted(String)
    public var errorDescription: String? { switch self { case .notStarted(let message): return message } }
}

public struct BatteryGateError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum BatteryGateLayout: String, Codable, Sendable {
    case legacyPair, chte
    var keys: [FourCC] { self == .legacyPair ? ["CH0B", "CH0C"] : ["CHTE"] }
    var enabled: [UInt8] { self == .legacyPair ? [0] : [0, 0, 0, 0] }
    var inhibited: [UInt8] { self == .legacyPair ? [2] : [1, 0, 0, 0] }
    func accepts(_ info: SMCKeyInfo) -> Bool {
        keys.contains(info.key) && info.size == enabled.count && info.attributes == 0xd4 &&
            (self == .chte ? info.type == "ui32" : [FourCC("hex_"), "ui8 "].contains(info.type))
    }
}

/// The recovery payload cannot authorize arbitrary keys, types or byte writes.
/// Acquisition starts only from all-zero registers, never an external hold.
public struct BatteryGateRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let hardwareID: String
    public let layout: BatteryGateLayout
    public let registers: [SMCKeyInfo]
    public init(hardwareID: String, layout: BatteryGateLayout, registers: [SMCKeyInfo]) {
        version = 1; self.hardwareID = hardwareID; self.layout = layout; self.registers = registers
    }
    public var valid: Bool {
        version == 1 && UUID(uuidString: hardwareID) != nil &&
            registers.map(\.key) == layout.keys && registers.allSatisfy(layout.accepts)
    }
}

public struct BatteryGateIO {
    public var info: (FourCC) throws -> SMCKeyInfo?
    public var read: (FourCC) throws -> SMCValue
    public var write: (FourCC, [UInt8]) throws -> Void
    public init(info: @escaping (FourCC) throws -> SMCKeyInfo?, read: @escaping (FourCC) throws -> SMCValue,
                write: @escaping (FourCC, [UInt8]) throws -> Void) {
        self.info = info; self.read = read; self.write = write
    }
    public static func system(_ smc: SMC) -> Self {
        .init(info: { key in
            do { return try smc.info(key) }
            catch SMCError.keyNotFound { return nil }
        }, read: smc.read, write: { try smc.write($0, bytes: $1) })
    }
}

/// save must complete durable persistence before returning. clear must remove
/// only the same validated record, under the store's lifetime exclusive lock.
public struct BatteryGateStore {
    public var load: () throws -> BatteryGateRecord?
    public var save: (BatteryGateRecord) throws -> Void
    public var clear: (BatteryGateRecord) throws -> Void
    public init(load: @escaping () throws -> BatteryGateRecord?, save: @escaping (BatteryGateRecord) throws -> Void,
                clear: @escaping (BatteryGateRecord) throws -> Void) {
        self.load = load; self.save = save; self.clear = clear
    }
}

/// Caller serializes all operations on one helper queue. This controls the SMC
/// gate only; it does not assert actual charging, implement a timer or accept XPC.
/// The helper must call recover() at startup and retry failures. New acquisitions
/// restore a predecessor's lease rather than resuming a persisted hold.
public final class BatteryChargingGate {
    private let io: BatteryGateIO
    private let store: BatteryGateStore
    private let hardwareID: () -> String?
    private var record: BatteryGateRecord?
    private var holdingConfirmed = false
    public private(set) var lastError: String?
    public init(io: BatteryGateIO, store: BatteryGateStore, hardwareID: @escaping () -> String?) {
        self.io = io; self.store = store; self.hardwareID = hardwareID
    }
    private func failure(_ message: String) -> BatteryGateError { .init("Charging gate: " + message) }
    private func sameHardware(_ record: BatteryGateRecord) -> Bool {
        guard let current = hardwareID(), let a = UUID(uuidString: current),
              let b = UUID(uuidString: record.hardwareID) else { return false }
        return a == b
    }
    private func read(_ info: SMCKeyInfo, record: BatteryGateRecord) throws -> [UInt8] {
        guard sameHardware(record), try io.info(info.key) == info else { throw failure("hardware or register metadata changed") }
        let value = try io.read(info.key)
        guard value.key == info.key, value.type == info.type, value.bytes.count == info.size,
              sameHardware(record) else { throw failure("register read is incomplete or changed") }
        return value.bytes
    }
    private func probe() throws -> BatteryGateRecord {
        guard let id = hardwareID(), UUID(uuidString: id) != nil else { throw failure("hardware identity unavailable") }
        let first = try io.info("CH0B"), second = try io.info("CH0C")
        let layout: BatteryGateLayout, registers: [SMCKeyInfo]
        if let first, let second {
            layout = .legacyPair; registers = [first, second]
        } else if let chte = try io.info("CHTE") {
            layout = .chte; registers = [chte]
        } else { throw failure("supported charging registers not found") }
        let result = BatteryGateRecord(hardwareID: id, layout: layout, registers: registers)
        guard result.valid else { throw failure("unsupported charging register metadata") }
        return result
    }
    public func observation() -> (gate: BatteryChargePolicy.Gate, ownership: BatteryChargePolicy.Ownership) {
        do {
            let saved = try record ?? store.load()
            let candidate = try saved ?? probe()
            guard candidate.valid else { throw failure("invalid recovery record") }
            let values = try candidate.registers.map { try read($0, record: candidate) }
            if saved != nil {
                // A loaded predecessor's record always needs recovery first.
                guard record != nil, holdingConfirmed else { return (.unknown, .uncertain) }
                if values.allSatisfy({ $0 == candidate.layout.inhibited }) { return (.inhibited, .owned) }
                holdingConfirmed = false
                return (.unknown, .uncertain)
            }
            if values.allSatisfy({ $0 == candidate.layout.enabled }) { lastError = nil; return (.allowed, .none) }
            if values.allSatisfy({ $0 == candidate.layout.inhibited }) { lastError = nil; return (.inhibited, .none) }
            throw failure("unknown or inconsistent charging register values")
        } catch {
            holdingConfirmed = false; lastError = error.localizedDescription
            return (.unknown, record == nil ? .none : .uncertain)
        }
    }
    public func inhibit() throws {
        // Existing leases are restored before a new acquisition. A live caller
        // uses observation() to avoid calling inhibit again for its own hold.
        guard recover() else { throw failure(lastError ?? "recovery pending") }
        let candidate = try probe()
        for info in candidate.registers {
            guard try read(info, record: candidate) == candidate.layout.enabled else {
                throw failure("charging is already held or has an unknown state")
            }
        }
        // A failed/uncertain save may leave a record; no hardware write follows it.
        try store.save(candidate)
        record = candidate
        do {
            guard try candidate.registers.allSatisfy({ try read($0, record: candidate) == candidate.layout.enabled }) else {
                throw failure("register changed while persisting recovery record")
            }
            for info in candidate.registers {
                guard try read(info, record: candidate) == candidate.layout.enabled else { throw failure("register changed before acquisition") }
                try io.write(info.key, candidate.layout.inhibited)
                guard try read(info, record: candidate) == candidate.layout.inhibited else { throw failure("charging hold readback failed") }
            }
            guard try candidate.registers.allSatisfy({ try read($0, record: candidate) == candidate.layout.inhibited }) else {
                throw failure("charging hold changed during acquisition")
            }
            holdingConfirmed = true; lastError = nil
        } catch {
            let original = error.localizedDescription
            let restored = recover()
            throw failure(original + (restored ? "; original state restored" : "; recovery pending: " + (lastError ?? "unknown")))
        }
    }
    @discardableResult public func recover() -> Bool {
        holdingConfirmed = false
        do {
            if record == nil { record = try store.load() }
            guard let candidate = record else { lastError = nil; return true }
            guard candidate.valid, sameHardware(candidate) else { throw failure("recovery identity is invalid or unavailable") }
            // Preflight every key before touching any: unknown third-party values
            // must not be overwritten even when another key still matches ours.
            for info in candidate.registers {
                let value = try read(info, record: candidate)
                guard value == candidate.layout.enabled || value == candidate.layout.inhibited else { throw failure("external register value prevents recovery") }
            }
            for info in candidate.registers {
                let value = try read(info, record: candidate)
                if value == candidate.layout.inhibited {
                    try io.write(info.key, candidate.layout.enabled)
                } else if value != candidate.layout.enabled { throw failure("register changed during recovery") }
                guard try read(info, record: candidate) == candidate.layout.enabled else { throw failure("charging restoration readback failed") }
            }
            guard try candidate.registers.allSatisfy({ try read($0, record: candidate) == candidate.layout.enabled }) else { throw failure("charging restoration changed") }
            try store.clear(candidate)
            record = nil; lastError = nil
            return true
        } catch { lastError = error.localizedDescription; return false }
    }
}
