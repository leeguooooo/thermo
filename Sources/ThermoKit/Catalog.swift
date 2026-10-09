import Foundation

/// Knowledge about SMC key names. Curated keys get friendly names and are shown by
/// default; every other plausible sensor is still reported with `known == false`.
public enum Catalog {
    public struct Entry: Sendable {
        public let name: String
        public let group: SensorGroup
    }

    // MARK: Temperatures

    static let temperatures: [String: Entry] = {
        var t: [String: Entry] = [
            // CPU (Intel)
            "TC0P": .init(name: "CPU Proximity", group: .cpu),
            "TC0D": .init(name: "CPU Die", group: .cpu),
            "TC0E": .init(name: "CPU Die (virtual)", group: .cpu),
            "TC0F": .init(name: "CPU Die (filtered)", group: .cpu),
            "TC0H": .init(name: "CPU Heatsink", group: .cpu),
            "TCXC": .init(name: "CPU PECI", group: .cpu),
            "TCMX": .init(name: "CPU Max", group: .cpu),
            "TCGC": .init(name: "CPU Integrated GPU", group: .cpu),
            "TCSA": .init(name: "CPU System Agent", group: .cpu),
            "TCAD": .init(name: "CPU Package", group: .cpu),
            // GPU
            "TG0P": .init(name: "GPU Proximity", group: .gpu),
            "TG1P": .init(name: "GPU Proximity 2", group: .gpu),
            "TG0D": .init(name: "GPU Die", group: .gpu),
            "TG0H": .init(name: "GPU Heatsink", group: .gpu),
            "TGDD": .init(name: "GPU Die (digital)", group: .gpu),
            "TGDE": .init(name: "GPU Die (estimated)", group: .gpu),
            "TGDF": .init(name: "GPU Die (filtered)", group: .gpu),
            "TGVF": .init(name: "GPU VRAM (filtered)", group: .gpu),
            "TGVP": .init(name: "GPU VRAM Proximity", group: .gpu),
            // Memory / board
            "TM0P": .init(name: "Memory Proximity", group: .memory),
            "TM0S": .init(name: "Memory Slot", group: .memory),
            "Tm0P": .init(name: "Mainboard Proximity", group: .board),
            "TPCD": .init(name: "Platform Controller Hub", group: .board),
            "TW0P": .init(name: "Wi-Fi Module", group: .board),
            "Th0H": .init(name: "Heatpipe 0", group: .board),
            "Th1H": .init(name: "Heatpipe 1", group: .board),
            "Th2H": .init(name: "Heatpipe 2", group: .board),
            "TTLD": .init(name: "Thunderbolt Left", group: .board),
            "TTRD": .init(name: "Thunderbolt Right", group: .board),
            "TaLC": .init(name: "Airflow Left", group: .board),
            "TaRC": .init(name: "Airflow Right", group: .board),
            "TI0P": .init(name: "Thunderbolt 1", group: .board),
            "TI1P": .init(name: "Thunderbolt 2", group: .board),
            // Storage
            "TH0F": .init(name: "SSD (filtered)", group: .storage),
            "TH0X": .init(name: "SSD (max)", group: .storage),
            "TH0P": .init(name: "SSD Proximity", group: .storage),
            "TH0a": .init(name: "SSD A", group: .storage),
            "TH0b": .init(name: "SSD B", group: .storage),
            "TH1a": .init(name: "SSD C", group: .storage),
            "TH1b": .init(name: "SSD D", group: .storage),
            "TN0D": .init(name: "Northbridge Die", group: .board),
            "TN0P": .init(name: "Northbridge Proximity", group: .board),
            // Battery
            "TB0T": .init(name: "Battery", group: .battery),
            "TB1T": .init(name: "Battery Cell 1", group: .battery),
            "TB2T": .init(name: "Battery Cell 2", group: .battery),
            "TB3T": .init(name: "Battery Cell 3", group: .battery),
            // Ambient / skin
            "TA0P": .init(name: "Ambient", group: .ambient),
            "TA0V": .init(name: "Ambient", group: .ambient),
            "TA1P": .init(name: "Ambient 2", group: .ambient),
            "Ts0P": .init(name: "Palm Rest", group: .ambient),
            "Ts1P": .init(name: "Palm Rest 2", group: .ambient),
            "Ts0S": .init(name: "Bottom Skin 1", group: .ambient),
            "Ts1S": .init(name: "Bottom Skin 2", group: .ambient),
            "Ts2S": .init(name: "Bottom Skin 3", group: .ambient),
        ]
        // Intel per-core sensors: TC1C ... TCFC
        for i in 1..<16 {
            t["TC\(String(i, radix: 16, uppercase: true))C"] = .init(name: "CPU Core \(i)", group: .cpu)
        }
        return t
    }()

    /// Name + group for a temperature key. Apple Silicon core keys (Tp**, Te**, Tg**) are
    /// chip-specific, so they are named by pattern.
    public static func temperature(_ key: String) -> (entry: Entry, known: Bool) {
        if let e = temperatures[key] { return (e, true) }
        let chars = Array(key)
        guard chars.count == 4, chars[0] == "T" else { return (.init(name: key, group: .other), false) }
        let suffix = String(chars[2...])
        switch chars[1] {
        case "p": return (.init(name: "CPU P-Core \(suffix)", group: .cpu), true)
        case "e": return (.init(name: "CPU E-Core \(suffix)", group: .cpu), true)
        case "g": return (.init(name: "GPU \(suffix)", group: .gpu), true)
        case "C": return (.init(name: "CPU \(suffix)", group: .cpu), false)
        case "G": return (.init(name: "GPU \(suffix)", group: .gpu), false)
        case "M": return (.init(name: "Memory \(suffix)", group: .memory), false)
        case "H": return (.init(name: "Storage \(suffix)", group: .storage), false)
        case "B": return (.init(name: "Battery \(suffix)", group: .battery), false)
        case "A", "s": return (.init(name: key, group: .ambient), false)
        default: return (.init(name: key, group: .other), false)
        }
    }

    /// Classify an IOHID temperature sensor by its product name.
    public static func hidGroup(_ name: String) -> SensorGroup {
        let n = name.lowercased()
        if n.contains("gpu") { return .gpu }
        if n.contains("pacc") || n.contains("eacc") || n.contains("soc") || n.contains("pmu tdie") || n.contains("cpu") { return .cpu }
        if n.contains("nand") || n.contains("ssd") { return .storage }
        if n.contains("battery") || n.contains("gas gauge") { return .battery }
        if n.contains("ambient") || n.contains("skin") { return .ambient }
        return .board
    }

    /// Representative keys read by `.essential` sampling. Apple Silicon core sensors
    /// (Tp/Te/Tg) are cheap to read there and drive curves, so they are always included.
    static let essentialKeys: Set<String> = [
        "TC0P", "TC0D", "TC0E", "TCXC", "TCMX", "TCAD",
        "TG0P", "TG0D", "TGDF",
        "TM0P", "TH0X", "TH0F", "TB0T", "TA0P", "TA0V", "Ts0P",
        "PSTR", "PDTR", "PCPC", "PCPT", "PCPG", "PG0R",
    ]

    public static func isEssential(_ key: String) -> Bool {
        if essentialKeys.contains(key) { return true }
        let c = Array(key)
        return c.count == 4 && c[0] == "T" && (c[1] == "p" || c[1] == "e" || c[1] == "g")
    }

    // MARK: Power / voltage / current

    static let power: [String: String] = [
        "PSTR": "System Total",
        "PDTR": "DC In",
        "PPBR": "Battery",
        "PCPC": "CPU Package",
        "PCPT": "CPU Package Total",
        "PCPG": "CPU Graphics",
        "PC0R": "CPU Rail",
        "PCPR": "CPU",
        "PG0R": "GPU Rail",
        "PGTR": "GPU",
        "PM0C": "Memory",
        "PZ0E": "Power Zone 0",
        "PMVC": "Memory",
        "PH0C": "Storage",
    ]

    static let voltages: [String: String] = [
        "VD0R": "DC In",
        "VP0R": "Main Rail",
        "VCAC": "CPU Core",
        "VG0C": "GPU Core",
        "VBAT": "Battery",
        "VC0C": "CPU Core",
    ]

    static let currents: [String: String] = [
        "ID0R": "DC In",
        "IC0R": "CPU Rail",
        "IBAC": "Battery",
        "IM0C": "Memory",
        "IPBR": "Battery Rail",
        "IG0R": "GPU Rail",
        "IC0C": "CPU Core",
    ]

    public static func quantity(of key: String) -> Quantity? {
        switch key.first {
        case "T": return .temperature
        case "P": return .power
        case "V": return .voltage
        case "I": return .current
        default: return nil
        }
    }

    public static func name(_ key: String, quantity: Quantity) -> (name: String, known: Bool) {
        let table: [String: String]
        switch quantity {
        case .temperature: let r = temperature(key); return (r.entry.name, r.known)
        case .power: table = power
        case .voltage: table = voltages
        case .current: table = currents
        }
        if let n = table[key] { return (n, true) }
        return (key, false)
    }

    /// Plausible range for discovery; rejects disconnected or placeholder sensors.
    public static func plausible(_ value: Double, _ q: Quantity) -> Bool {
        guard value.isFinite else { return false }
        switch q {
        case .temperature: return value > 1 && value < 130
        case .power: return value >= 0 && value < 1000
        case .voltage: return value >= 0 && value < 100
        case .current: return value > -50 && value < 50
        }
    }
}
