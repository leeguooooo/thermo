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

    public let lowercaseModeKey: Bool?

    init(index: Int, name: String, hasModeKey: Bool, lowercaseModeKey: Bool = false) {
        self.index = index; self.name = name; self.hasModeKey = hasModeKey
        self.lowercaseModeKey = hasModeKey && lowercaseModeKey ? true : nil
    }

    static func discover(index: Int, name: String, hasKey: (FourCC) -> Bool) -> FanDescriptor {
        let c = String(index, radix: 16, uppercase: true)
        let upper = hasKey(FourCC("F\(c)Md"))
        let lower = !upper && hasKey(FourCC("F\(c)md"))
        return FanDescriptor(index: index, name: name, hasModeKey: upper || lower, lowercaseModeKey: lower)
    }

    var c: String { String(index, radix: 16, uppercase: true) }
    public var actualKey: FourCC { FourCC("F\(c)Ac") }
    public var minKey: FourCC { FourCC("F\(c)Mn") }
    public var maxKey: FourCC { FourCC("F\(c)Mx") }
    public var targetKey: FourCC { FourCC("F\(c)Tg") }
    public var modeKey: FourCC { FourCC("F\(c)\(lowercaseModeKey == true ? "md" : "Md")") }
}

/// The result of scanning the SMC once. Cached on disk per machine model + key count,
/// so subsequent launches skip the ~1000-key enumeration.
public struct Discovery: Codable, Sendable {
    static let version = 4
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
    /// nil in legacy JSON; an empty legacy list does not prove the absence of fans.
    public let fanCountKnown: Bool?
    public var fansKnown: Bool { fanCountKnown ?? !fans.isEmpty }

    init(version: Int, model: String, keyCount: UInt32, sensors: [SensorDescriptor], fans: [FanDescriptor],
         fanForceKey: Bool, fanTestKey: Bool, hid: Bool, fanCountKnown: Bool? = true) {
        self.version = version; self.model = model; self.keyCount = keyCount
        self.sensors = sensors; self.fans = fans; self.fanForceKey = fanForceKey
        self.fanTestKey = fanTestKey; self.hid = hid; self.fanCountKnown = fanCountKnown
    }

    func recoveringFans(_ read: () -> [FanDescriptor]?) -> Discovery {
        guard !fansKnown, let recovered = read() else { return self }
        return Discovery(version: version, model: model, keyCount: keyCount, sensors: sensors,
                         fans: recovered, fanForceKey: fanForceKey, fanTestKey: fanTestKey, hid: hid)
    }
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

public enum SamplerScope: Equatable, Sendable {
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
    public private(set) var discovery: Discovery
    public var scope: SamplerScope
    /// What `sample()` reads; skip parts you don't display to save SMC round-trips.
    public var parts: SamplerParts = .everything
    /// Restrict temperature sensors to these groups (nil = all groups).
    public var groups: Set<SensorGroup>?

    private let useCache: Bool
    private let hid: OpaquePointer?
    private var hidBuffer: [smc_hid_reading]

    /// Fan min/max are near-static; refresh them occasionally instead of every sample.
    private var fanLimits: [Int: (min: Double?, max: Double?)] = [:]
    private var fanLimitsRead = Date.distantPast
    public var fanLimitRefresh: TimeInterval = 30

    public init(smc: SMC? = nil, scope: SamplerScope = .known, useCache: Bool = true) throws {
        let smc = try smc ?? SMC()
        self.smc = smc
        self.scope = scope
        self.useCache = useCache
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
        return Snapshot(temperatures: temps, fans: fans, power: power, voltages: volts, currents: amps,
                        battery: battery, fansAvailable: parts.contains(.fans) ? discovery.fansKnown : nil)
    }

    public func invalidateFanLimits() { fanLimitsRead = .distantPast }

    private func readFans() -> [FanReading] {
        if !discovery.fansKnown {
            discovery = discovery.recoveringFans { Self.discoverFans(smc: smc) }
            if useCache, discovery.fansKnown { Self.saveDiscovery(discovery) }
        }
        guard discovery.fansKnown, !discovery.fans.isEmpty else { return [] }
        if Date().timeIntervalSince(fanLimitsRead) > fanLimitRefresh {
            for f in discovery.fans {
                fanLimits[f.index] = (try? smc.double(f.minKey), try? smc.double(f.maxKey))
            }
            fanLimitsRead = Date()
        }
        return FanSampler.read(discovery.fans, hasForceKey: discovery.fanForceKey, limits: fanLimits) {
            try smc.double($0)
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
           d.version == Discovery.version, d.model == model, d.keyCount == count, d.fansKnown {
            for s in d.sensors { smc.seed(s.info) }
            return d
        }
        let d = try discover(smc: smc, model: model, count: count)
        if useCache { saveDiscovery(d) }
        return d
    }

    static func saveDiscovery(_ discovery: Discovery, to url: URL = cacheURL) {
        guard discovery.fansKnown else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? discovery.cacheData.write(to: url, options: .atomic)
    }

    static func discoverFans(readCount: () throws -> Double,
                             descriptor: (Int, Int) -> FanDescriptor) -> [FanDescriptor]? {
        guard let raw = try? readCount(), raw.isFinite, raw.rounded() == raw, (0...16).contains(raw) else { return nil }
        let count = Int(raw)
        return (0..<count).map { descriptor($0, count) }
    }

    private static func discoverFans(smc: SMC) -> [FanDescriptor]? {
        discoverFans(readCount: { try smc.double("FNum") }) { i, count in
            let c = String(i, radix: 16, uppercase: true)
            let name = fanName(smc: smc, key: FourCC("F\(c)ID")) ?? (count > 1 ? "Fan \(i + 1)" : "Fan")
            return FanDescriptor.discover(index: i, name: name, hasKey: smc.has)
        }
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

        let discoveredFans = discoverFans(smc: smc)
        var hasHID = false
        #if arch(arm64)
        if let h = smc_hid_open() { hasHID = smc_hid_count(h) > 0; smc_hid_close(h) }
        #endif

        return Discovery(version: Discovery.version, model: model, keyCount: n, sensors: sensors, fans: discoveredFans ?? [],
                         fanForceKey: hasForce, fanTestKey: hasTest, hid: hasHID, fanCountKnown: discoveredFans != nil)
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
//   thermo-discovery <version> <keyCount> <forceKey> <testKey> <hid> <fanCount-or-?>
//   model <model>
//   s <key> <type> <size> <attr> <quantity> <group> <known> <essential> <name...>
//   f <index> <mode: 0 absent, 1 Md, 2 md> <name...>
// Keys and types are hex-encoded FourCCs because they may contain spaces.

extension Discovery {
    var cacheData: Data {
        var out = "thermo-discovery \(version) \(keyCount) \(fanForceKey ? 1 : 0) \(fanTestKey ? 1 : 0) \(hid ? 1 : 0) \(fansKnown ? String(fans.count) : "?")\n"
        out += "model \(model)\n"
        for s in sensors {
            out += "s \(String(s.info.key.rawValue, radix: 16)) \(String(s.info.type.rawValue, radix: 16)) \(s.info.size) \(s.info.attributes) "
                + "\(s.quantity.rawValue) \(s.group.rawValue) \(s.known ? 1 : 0) \(s.essential ? 1 : 0) \(s.name)\n"
        }
        for f in fans { out += "f \(f.index) \(f.hasModeKey ? (f.lowercaseModeKey == true ? 2 : 1) : 0) \(f.name)\n" }
        out += "end \(sensors.count) \(fans.count)\n"
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
                let product = v.multipliedReportingOverflow(by: T(radix))
                let sum = product.partialValue.addingReportingOverflow(T(d))
                guard !product.overflow, !sum.overflow else { return nil }
                v = sum.partialValue
            }
            return v
        }
        func bit(_ field: ArraySlice<UInt8>) -> Bool? {
            guard field.count == 1 else { return nil }
            if field.first == 48 { return false }
            if field.first == 49 { return true }
            return nil
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
        var expectedFans: Int?, expectedSensors: Int?, footerFans: Int?
        var sawHeader = false, sawModel = false, sawEnd = false
        var model = ""
        var sensors: [SensorDescriptor] = []
        var fans: [FanDescriptor] = []
        sensors.reserveCapacity(256)
        for line in bytes.split(separator: 10) {
            guard !sawEnd else { return nil }
            switch line.first {
            case UInt8(ascii: "t"):
                let f = fields(line, max: 7)
                guard !sawHeader, f.count == 7, str(f[0]) == "thermo-discovery",
                      let v: Int = num(f[1]), let k: UInt32 = num(f[2]),
                      let forceBit = bit(f[3]), let testBit = bit(f[4]), let hidBit = bit(f[5]) else { return nil }
                if str(f[6]) != "?" {
                    guard let count: Int = num(f[6]), (0...16).contains(count) else { return nil }
                    expectedFans = count
                }
                sawHeader = true; version = v; keyCount = k
                force = forceBit; test = testBit; hid = hidBit
            case UInt8(ascii: "m"):
                guard !sawModel, line.starts(with: Array("model ".utf8)) else { return nil }
                sawModel = true; model = str(line.dropFirst(6))
            case UInt8(ascii: "s"):
                let f = fields(line, max: 10)
                guard f.count == 10, str(f[0]) == "s", let known = bit(f[7]), let essential = bit(f[8]),
                      let key: UInt32 = num(f[1], 16), let type: UInt32 = num(f[2], 16),
                      let size: UInt32 = num(f[3]), let attr: UInt8 = num(f[4]),
                      let q = Quantity(rawValue: str(f[5])), let g = SensorGroup(rawValue: str(f[6])) else { return nil }
                sensors.append(SensorDescriptor(info: SMCKeyInfo(key: FourCC(key), type: FourCC(type), size: size, attributes: attr),
                                                quantity: q, name: str(f[9]), group: g,
                                                known: known, essential: essential))
            case UInt8(ascii: "f"):
                let f = fields(line, max: 4)
                guard f.count == 4, str(f[0]) == "f", let mode: Int = num(f[2]), (0...2).contains(mode),
                      let i: Int = num(f[1]), (0..<16).contains(i),
                      !fans.contains(where: { $0.index == i }) else { return nil }
                fans.append(FanDescriptor(index: i, name: str(f[3]), hasModeKey: mode != 0, lowercaseModeKey: mode == 2))
            case UInt8(ascii: "e"):
                let f = fields(line, max: 3)
                guard f.count == 3, str(f[0]) == "end", let sensorCount: Int = num(f[1]),
                      let fanCount: Int = num(f[2]) else { return nil }
                expectedSensors = sensorCount; footerFans = fanCount; sawEnd = true
            default:
                return nil
            }
        }
        guard version == Discovery.version, sawHeader, sawModel, sawEnd, !model.isEmpty,
              expectedSensors == sensors.count, footerFans == fans.count else { return nil }
        if let expectedFans {
            guard fans.count == expectedFans, Set(fans.map(\.index)) == Set(0..<expectedFans) else { return nil }
        } else if !fans.isEmpty { return nil }
        self.init(version: version, model: model, keyCount: keyCount, sensors: sensors, fans: fans,
                  fanForceKey: force, fanTestKey: test, hid: hid, fanCountKnown: expectedFans != nil)
    }
}
