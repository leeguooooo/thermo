import CSMC
import Foundation

/// A sensor discovered on this machine.
public struct SensorDescriptor: Codable, Hashable, Sendable {
    public let info: SMCKeyInfo
    public let quantity: Quantity
    public let name: String
    public let group: SensorGroup
    public let known: Bool
    /// Part of the minimal set read by `.essential` sampling.
    public let essential: Bool
}

public struct FanDescriptor: Codable, Hashable, Sendable {
    public let index: Int
    public let name: String
    public let hasModeKey: Bool

    var c: String { String(index, radix: 16, uppercase: true) }
    public var actualKey: FourCC { FourCC("F\(c)Ac") }
    public var minKey: FourCC { FourCC("F\(c)Mn") }
    public var maxKey: FourCC { FourCC("F\(c)Mx") }
    public var targetKey: FourCC { FourCC("F\(c)Tg") }
    public var modeKey: FourCC { FourCC("F\(c)Md") }
}

/// The result of scanning the SMC once. Cached on disk per machine model + key count,
/// so subsequent launches skip the ~1000-key enumeration.
public struct Discovery: Codable, Sendable {
    static let version = 2
    public let version: Int
    public let model: String
    public let keyCount: UInt32
    public let sensors: [SensorDescriptor]
    public let fans: [FanDescriptor]
    /// Keys needed by fan control that were seen at discovery time.
    public let fanForceKey: Bool   // "FS! "
    public let fanTestKey: Bool    // "Ftst" (Apple Silicon unlock)
    /// IOHID temperature services exist (Apple Silicon).
    public let hid: Bool
}

public struct SamplerParts: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let temperatures = SamplerParts(rawValue: 1)
    public static let fans = SamplerParts(rawValue: 2)
    public static let power = SamplerParts(rawValue: 4)
    /// Voltages and currents.
    public static let electrical = SamplerParts(rawValue: 8)
    public static let battery = SamplerParts(rawValue: 16)
    public static let everything: SamplerParts = [.temperatures, .fans, .power, .electrical, .battery]
}

public enum SamplerScope: Sendable {
    /// A few representative sensors per group, fans and headline power. Cheapest;
    /// meant for background polling (menu bar title, curve control).
    case essential
    /// Curated sensors only (default).
    case known
    /// Every plausible sensor.
    case all
}

/// Reads snapshots. Discovery happens once; each `sample()` only touches known keys.
/// Not thread-safe: use from one thread/queue.
public final class Sampler {
    public let smc: SMC
    public let discovery: Discovery
    public var scope: SamplerScope
    /// What `sample()` reads; skip parts you don't display to save SMC round-trips.
    public var parts: SamplerParts = .everything
    /// Restrict temperature sensors to these groups (nil = all groups).
    public var groups: Set<SensorGroup>?

    private let hid: OpaquePointer?
    private var hidBuffer: [smc_hid_reading]

    /// Fan min/max are near-static; refresh them occasionally instead of every sample.
    private var fanLimits: [Int: (min: Double, max: Double)] = [:]
    private var fanLimitsRead = Date.distantPast
    public var fanLimitRefresh: TimeInterval = 30

    public init(smc: SMC? = nil, scope: SamplerScope = .known, useCache: Bool = true) throws {
        let smc = try smc ?? SMC()
        self.smc = smc
        self.scope = scope
        self.discovery = try Sampler.loadDiscovery(smc: smc, useCache: useCache)
        self.hid = discovery.hid ? smc_hid_open() : nil
        self.hidBuffer = Array(repeating: smc_hid_reading(), count: Int(smc_hid_count(hid)))
    }

    deinit { smc_hid_close(hid) }

    public var fans: [FanDescriptor] { discovery.fans }

    public func sample() -> Snapshot {
        var temps: [Reading] = []
        var power: [Reading] = []
        var volts: [Reading] = []
        var amps: [Reading] = []
        temps.reserveCapacity(64)

        for s in discovery.sensors where scope == .all || (scope == .known ? s.known : s.essential) {
            switch s.quantity {
            case .temperature:
                guard parts.contains(.temperatures), groups?.contains(s.group) ?? true else { continue }
            case .power: guard parts.contains(.power) else { continue }
            case .voltage, .current: guard parts.contains(.electrical) else { continue }
            }
            guard let v = try? smc.double(s.info.key) else { continue }
            if s.quantity == .temperature && !Catalog.plausible(v, .temperature) { continue }
            let r = Reading(key: s.info.key.description, name: s.name, group: s.group, value: v, known: s.known)
            switch s.quantity {
            case .temperature: temps.append(r)
            case .power: power.append(r)
            case .voltage: volts.append(r)
            case .current: amps.append(r)
            }
        }

        // IOHID reads cost ~1 ms per service; SMC already covers CPU/GPU, so skip them in .essential.
        if let hid, !hidBuffer.isEmpty, parts.contains(.temperatures), scope != .essential {
            let n = hidBuffer.withUnsafeMutableBufferPointer { smc_hid_read(hid, $0.baseAddress, Int32($0.count)) }
            var seen: [String: Int] = [:]
            for i in 0..<Int(n) {
                let name = withUnsafeBytes(of: hidBuffer[i].name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                // Several services share a product name ("gas gauge battery"); keep keys unique.
                let count = (seen[name] ?? 0) + 1
                seen[name] = count
                let label = count > 1 ? "\(name) \(count)" : name
                temps.append(Reading(key: "hid:\(label)", name: label, group: Catalog.hidGroup(name),
                                     value: hidBuffer[i].celsius, known: true))
            }
        }

        let fans = parts.contains(.fans) ? readFans() : []

        var battery = parts.contains(.battery) ? Battery.read() : nil
        if let b = battery, b.temperature == nil {
            // Recent macOS no longer publishes the battery temperature in IORegistry; use the SMC sensor.
            let t = temps.first { $0.key == "TB0T" }?.value ?? (try? smc.double("TB0T"))
            battery = b.with(temperature: t)
        }
        return Snapshot(temperatures: temps, fans: fans, power: power, voltages: volts, currents: amps, battery: battery)
    }

    public func invalidateFanLimits() { fanLimitsRead = .distantPast }

    private func readFans() -> [FanReading] {
        guard !discovery.fans.isEmpty else { return [] }
        if Date().timeIntervalSince(fanLimitsRead) > fanLimitRefresh {
            for f in discovery.fans {
                fanLimits[f.index] = ((try? smc.double(f.minKey)) ?? 0, (try? smc.double(f.maxKey)) ?? 0)
            }
            fanLimitsRead = Date()
        }
        let forceBits = discovery.fanForceKey ? (try? smc.double("FS! ")).map { Int($0) } : nil
        return discovery.fans.compactMap { f -> FanReading? in
            guard let rpm = try? smc.double(f.actualKey) else { return nil }
            let mode = f.hasModeKey ? (try? smc.double(f.modeKey)) : nil
            // F<i>Md: 1 = forced/manual. Apple Silicon reports 3 for system control and 0 when idle.
            let manual = mode == 1 || ((forceBits ?? 0) & (1 << f.index)) != 0
            let lim = fanLimits[f.index] ?? (0, 0)
            return FanReading(id: f.index, name: f.name, rpm: Swift.max(0, rpm), min: lim.min, max: lim.max,
                              target: manual ? try? smc.double(f.targetKey) : nil, manual: manual)
        }
    }

    // MARK: Discovery

    public static var machineModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// ~/Library/Caches/dev.thermo/… resolved without FileManager (its first use costs ~5 ms).
    static var cachePath: String {
        var home = getenv("HOME").map { String(cString: $0) }
        if home == nil || home!.isEmpty, let pw = getpwuid(getuid()) { home = String(cString: pw.pointee.pw_dir) }
        return (home ?? NSTemporaryDirectory()) + "/Library/Caches/dev.thermo/discovery-v\(Discovery.version).txt"
    }

    static var cacheURL: URL { URL(fileURLWithPath: cachePath) }

    static func readFile(_ path: String) -> Data? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    public static func clearCache() { try? FileManager.default.removeItem(at: cacheURL) }

    static func loadDiscovery(smc: SMC, useCache: Bool) throws -> Discovery {
        let model = machineModel
        let count = try smc.keyCount()
        if useCache, let data = readFile(cachePath),
           let d = Discovery(cache: data),
           d.version == Discovery.version, d.model == model, d.keyCount == count {
            for s in d.sensors { smc.seed(s.info) }
            return d
        }
        let d = try discover(smc: smc, model: model, count: count)
        if useCache {
            let data = d.cacheData
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
        return d
    }

    public static func discover(smc: SMC, model: String = machineModel, count: UInt32? = nil) throws -> Discovery {
        let n = try count ?? smc.keyCount()
        var sensors: [SensorDescriptor] = []
        var hasForce = false, hasTest = false
        var values: [String: Double] = [:]

        for i in 0..<n {
            guard let key = try? smc.key(at: i) else { continue }
            let ks = key.description
            if ks == "FS! " { hasForce = true; continue }
            if ks == "Ftst" { hasTest = true; continue }
            guard let q = Catalog.quantity(of: ks),
                  let info = try? smc.info(key),
                  let v = try? smc.double(key),
                  Catalog.plausible(v, q) else { continue }
            // Skip integer-typed keys for analog quantities: they are counters/limits, not sensors.
            let t = info.type.description
            if t.hasPrefix("ui") || t.hasPrefix("si") || t == "flag" || t == "hex_" { continue }
            let (name, known) = Catalog.name(ks, quantity: q)
            let group: SensorGroup = q == .temperature ? Catalog.temperature(ks).entry.group : .other
            sensors.append(SensorDescriptor(info: info, quantity: q, name: name, group: group, known: known,
                                            essential: known && Catalog.isEssential(ks)))
            values[ks] = v
        }

        // Every group with known temperature sensors keeps at least one essential member:
        // promote the hottest one seen during discovery.
        for g in SensorGroup.allCases {
            let members = sensors.indices.filter { sensors[$0].quantity == .temperature && sensors[$0].group == g && sensors[$0].known }
            guard !members.isEmpty, !members.contains(where: { sensors[$0].essential }) else { continue }
            let hottest = members.max { (values[sensors[$0].info.key.description] ?? 0) < (values[sensors[$1].info.key.description] ?? 0) }!
            let s = sensors[hottest]
            sensors[hottest] = SensorDescriptor(info: s.info, quantity: s.quantity, name: s.name, group: s.group,
                                                known: true, essential: true)
        }

        var fans: [FanDescriptor] = []
        let fanCount = Int((try? smc.double("FNum")) ?? 0)
        for i in 0..<min(fanCount, 16) {
            let c = String(i, radix: 16, uppercase: true)
            let name = fanName(smc: smc, key: FourCC("F\(c)ID")) ?? (fanCount > 1 ? "Fan \(i + 1)" : "Fan")
            fans.append(FanDescriptor(index: i, name: name, hasModeKey: smc.has(FourCC("F\(c)Md"))))
        }

        var hasHID = false
        #if arch(arm64)
        if let h = smc_hid_open() { hasHID = smc_hid_count(h) > 0; smc_hid_close(h) }
        #endif

        return Discovery(version: Discovery.version, model: model, keyCount: n, sensors: sensors, fans: fans,
                         fanForceKey: hasForce, fanTestKey: hasTest, hid: hasHID)
    }

    /// `F<i>ID` is a 16-byte struct on Intel; the name starts at offset 4.
    static func fanName(smc: SMC, key: FourCC) -> String? {
        guard let v = try? smc.read(key), v.bytes.count > 4 else { return nil }
        let name = String(decoding: v.bytes[4...].prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

// MARK: - Cache format
//
// Line-oriented text, parsed without Foundation's JSON machinery (~10x faster cold):
//   thermo-discovery <version> <keyCount> <forceKey> <testKey> <hid>
//   model <model>
//   s <key> <type> <size> <attr> <quantity> <group> <known> <essential> <name...>
//   f <index> <hasModeKey> <name...>
// Keys and types are hex-encoded FourCCs because they may contain spaces.

extension Discovery {
    var cacheData: Data {
        var out = "thermo-discovery \(version) \(keyCount) \(fanForceKey ? 1 : 0) \(fanTestKey ? 1 : 0) \(hid ? 1 : 0)\n"
        out += "model \(model)\n"
        for s in sensors {
            out += "s \(String(s.info.key.rawValue, radix: 16)) \(String(s.info.type.rawValue, radix: 16)) \(s.info.size) \(s.info.attributes) "
                + "\(s.quantity.rawValue) \(s.group.rawValue) \(s.known ? 1 : 0) \(s.essential ? 1 : 0) \(s.name)\n"
        }
        for f in fans { out += "f \(f.index) \(f.hasModeKey ? 1 : 0) \(f.name)\n" }
        return Data(out.utf8)
    }

    init?(cache data: Data) {
        // Byte-level parsing: String/Character splitting is ~10x slower here.
        let bytes = [UInt8](data)
        func str(_ f: ArraySlice<UInt8>) -> String { String(decoding: f, as: UTF8.self) }
        func num<T: FixedWidthInteger>(_ f: ArraySlice<UInt8>, _ radix: Int = 10) -> T? {
            var v: T = 0
            guard !f.isEmpty else { return nil }
            for c in f {
                let d: Int
                switch c {
                case 48...57: d = Int(c) - 48
                case 97...102: d = Int(c) - 87
                default: return nil
                }
                guard d < radix else { return nil }
                v = v &* T(radix) &+ T(d)
            }
            return v
        }
        /// Split a line on spaces into at most `max` fields; the last keeps the remainder.
        func fields(_ line: ArraySlice<UInt8>, max: Int) -> [ArraySlice<UInt8>] {
            var out: [ArraySlice<UInt8>] = []
            var start = line.startIndex
            for i in line.indices where line[i] == 32 && out.count < max - 1 {
                out.append(line[start..<i])
                start = i + 1
            }
            out.append(line[start..<line.endIndex])
            return out
        }

        var version = 0, keyCount: UInt32 = 0, force = false, test = false, hid = false
        var model = ""
        var sensors: [SensorDescriptor] = []
        var fans: [FanDescriptor] = []
        sensors.reserveCapacity(256)
        for line in bytes.split(separator: 10) {
            switch line.first {
            case UInt8(ascii: "t"):
                let f = fields(line, max: 6)
                guard f.count == 6, let v: Int = num(f[1]), let k: UInt32 = num(f[2]) else { return nil }
                version = v; keyCount = k
                force = f[3].first == 49; test = f[4].first == 49; hid = f[5].first == 49
            case UInt8(ascii: "m"):
                model = str(line.dropFirst(6))
            case UInt8(ascii: "s"):
                let f = fields(line, max: 10)
                guard f.count == 10, let key: UInt32 = num(f[1], 16), let type: UInt32 = num(f[2], 16),
                      let size: UInt32 = num(f[3]), let attr: UInt8 = num(f[4]),
                      let q = Quantity(rawValue: str(f[5])), let g = SensorGroup(rawValue: str(f[6])) else { return nil }
                sensors.append(SensorDescriptor(info: SMCKeyInfo(key: FourCC(key), type: FourCC(type), size: size, attributes: attr),
                                                quantity: q, name: str(f[9]), group: g,
                                                known: f[7].first == 49, essential: f[8].first == 49))
            case UInt8(ascii: "f"):
                let f = fields(line, max: 4)
                guard f.count == 4, let i: Int = num(f[1]) else { return nil }
                fans.append(FanDescriptor(index: i, name: str(f[3]), hasModeKey: f[2].first == 49))
            default:
                return nil
            }
        }
        guard version == Discovery.version else { return nil }
        self.init(version: version, model: model, keyCount: keyCount, sensors: sensors, fans: fans,
                  fanForceKey: force, fanTestKey: test, hid: hid)
    }
}
