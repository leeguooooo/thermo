import CSMC
import Foundation

/// Four-character SMC code (key or data type).
public struct FourCC: Hashable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: UInt32

    public init(_ rawValue: UInt32) { self.rawValue = rawValue }

    public init(_ string: String) {
        var v: UInt32 = 0
        var bytes = Array(string.utf8.prefix(4))
        while bytes.count < 4 { bytes.append(0x20) }
        for b in bytes { v = (v << 8) | UInt32(b) }
        rawValue = v
    }

    public init(stringLiteral value: String) { self.init(value) }

    public var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: rawValue >> $0) }
        return String(decoding: bytes.map { (0x20...0x7e).contains($0) ? $0 : 0x3f }, as: UTF8.self)
    }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

public enum SMCError: Error, CustomStringConvertible, Equatable {
    case noService
    case openFailed
    case keyNotFound(FourCC)
    case sizeMismatch(FourCC)
    case unsupportedType(FourCC, type: FourCC)
    case notPrivileged
    case firmware(FourCC)
    case outOfMemory
    case kernel(Int32)

    init(code: Int32, key: FourCC = "????", type: FourCC = "????") {
        switch Int(code) {
        case SMC_ERR_NO_SERVICE: self = .noService
        case SMC_ERR_OPEN: self = .openFailed
        case SMC_ERR_KEY_NOT_FOUND: self = .keyNotFound(key)
        case SMC_ERR_SIZE: self = .sizeMismatch(key)
        case SMC_ERR_TYPE: self = .unsupportedType(key, type: type)
        case SMC_ERR_NOT_PRIVILEGED: self = .notPrivileged
        case SMC_ERR_CALL: self = .firmware(key)
        case SMC_ERR_NOMEM: self = .outOfMemory
        default: self = .kernel(code)
        }
    }

    public var description: String {
        switch self {
        case .noService: return "AppleSMC service not found"
        case .openFailed: return "cannot open AppleSMC"
        case .keyNotFound(let k): return "SMC key '\(k)' not found"
        case .sizeMismatch(let k): return "SMC key '\(k)': size mismatch"
        case .unsupportedType(let k, let t): return "SMC key '\(k)': unsupported type '\(t)'"
        case .notPrivileged: return "SMC write requires root (install the helper: thermo helper install)"
        case .firmware(let k): return "SMC rejected request for '\(k)'"
        case .outOfMemory: return "out of memory"
        case .kernel(let c): return String(format: "IOKit error 0x%08x", UInt32(bitPattern: c))
        }
    }
}

public struct SMCKeyInfo: Codable, Hashable, Sendable {
    public let key: FourCC
    public let type: FourCC
    public let size: UInt32
    public let attributes: UInt8
}

public struct SMCValue: Sendable {
    public let key: FourCC
    public let type: FourCC
    public let bytes: [UInt8]

    /// Numeric value, when the type is decodable.
    public var doubleValue: Double? {
        var out = 0.0
        return bytes.withUnsafeBufferPointer {
            smc_decode_double(type.rawValue, $0.baseAddress, UInt32($0.count), &out)
        } ? out : nil
    }

    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }

    /// Human-readable rendering for raw listings.
    public var display: String {
        if let d = doubleValue {
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(format: "%.3f", d)
        }
        if type == "ch8*" || type == "{fds" {
            let printable = bytes.prefix { $0 != 0 }.filter { (0x20...0x7e).contains($0) }
            if !printable.isEmpty { return "\"" + String(decoding: printable, as: UTF8.self) + "\"" }
        }
        return "[" + hex + "]"
    }
}

/// A connection to the AppleSMC. Thread-safe; the underlying C layer serialises its cache.
public final class SMC: @unchecked Sendable {
    private let conn: OpaquePointer

    public init() throws {
        var c: OpaquePointer?
        let rc = smc_open(&c)
        guard rc == SMC_OK, let c else { throw SMCError(code: rc) }
        conn = c
    }

    deinit { smc_close(conn) }

    public func keyCount() throws -> UInt32 {
        var n: UInt32 = 0
        let rc = smc_key_count(conn, &n)
        guard rc == SMC_OK else { throw SMCError(code: rc, key: "#KEY") }
        return n
    }

    public func key(at index: UInt32) throws -> FourCC {
        var k: UInt32 = 0
        let rc = smc_key_at_index(conn, index, &k)
        guard rc == SMC_OK else { throw SMCError(code: rc) }
        return FourCC(k)
    }

    /// All keys, in firmware order.
    public func allKeys() throws -> [FourCC] {
        let n = try keyCount()
        var keys: [FourCC] = []
        keys.reserveCapacity(Int(n))
        for i in 0..<n {
            if let k = try? key(at: i) { keys.append(k) }
        }
        return keys
    }

    public func info(_ key: FourCC) throws -> SMCKeyInfo {
        var i = smc_key_info()
        let rc = smc_key_info_get(conn, key.rawValue, &i)
        guard rc == SMC_OK else { throw SMCError(code: rc, key: key) }
        return SMCKeyInfo(key: key, type: FourCC(i.type), size: i.size, attributes: i.attributes)
    }

    public func seed(_ info: SMCKeyInfo) {
        var i = smc_key_info(key: info.key.rawValue, type: info.type.rawValue, size: info.size, attributes: info.attributes)
        smc_key_info_seed(conn, &i)
    }

    public func has(_ key: FourCC) -> Bool { (try? info(key)) != nil }

    public func read(_ key: FourCC) throws -> SMCValue {
        var v = smc_value()
        let rc = smc_read(conn, key.rawValue, &v)
        guard rc == SMC_OK else { throw SMCError(code: rc, key: key) }
        let bytes = withUnsafeBytes(of: v.bytes) { Array($0.prefix(Int(v.size))) }
        return SMCValue(key: key, type: FourCC(v.type), bytes: bytes)
    }

    /// Hot path: read + decode in C without intermediate allocations.
    public func double(_ key: FourCC) throws -> Double {
        var d = 0.0
        let rc = smc_read_double(conn, key.rawValue, &d)
        guard rc == SMC_OK else {
            let type = (try? info(key).type) ?? "????"
            throw SMCError(code: rc, key: key, type: type)
        }
        return d
    }

    public func write(_ key: FourCC, bytes: [UInt8]) throws {
        let rc = bytes.withUnsafeBufferPointer { smc_write(conn, key.rawValue, $0.baseAddress, UInt32($0.count)) }
        guard rc == SMC_OK else { throw SMCError(code: rc, key: key) }
    }

    /// Encode `value` using the key's own SMC type and write it.
    public func write(_ key: FourCC, value: Double) throws {
        let i = try info(key)
        try write(key, bytes: try SMCCodec.encode(value, type: i.type, size: Int(i.size)))
    }
}

/// Pure type codecs, exposed for tests and tools.
public enum SMCCodec {
    public static func decode(_ bytes: [UInt8], type: FourCC) -> Double? {
        SMCValue(key: "????", type: type, bytes: bytes).doubleValue
    }

    public static func encode(_ value: Double, type: FourCC, size: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max(size, 1))
        let ok = out.withUnsafeMutableBufferPointer { smc_encode_double(type.rawValue, UInt32(size), value, $0.baseAddress) }
        guard ok, size <= 32 else { throw SMCError.unsupportedType("????", type: type) }
        return Array(out.prefix(size))
    }
}
