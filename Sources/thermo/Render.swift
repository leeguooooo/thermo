import Foundation
import ThermoKit

/// Text renderers. Each returns lines so `watch` can compose and trim them to the screen.
struct Renderer {
    var style: Style
    var showAll: Bool

    private var nameWidth: Int { 26 }

    func header(_ s: Snapshot, model: String) -> [String] {
        // strftime instead of DateFormatter: avoids loading ICU (~10 ms) for one timestamp.
        var t = time_t(s.timestamp.timeIntervalSince1970)
        var tmv = tm()
        localtime_r(&t, &tmv)
        var buf = [CChar](repeating: 0, count: 16)
        strftime(&buf, buf.count, "%H:%M:%S", &tmv)
        let time = String(cString: buf)
        return [style.bold("thermo") + style.dim(" · \(model) · \(time)")]
    }

    func overview(_ s: Snapshot) -> [String] {
        var lines: [String] = []
        let groups: [(SensorGroup, Double?)] = [
            (.cpu, s.cpuPower), (.gpu, s.power.first { $0.key == "PCPG" || $0.key == "PG0R" }?.value),
            (.memory, nil), (.storage, nil), (.battery, nil), (.ambient, nil),
        ]
        for (g, watts) in groups {
            guard let mx = s.maxTemperature(in: g) else { continue }
            let avg = s.averageTemperature(in: g)
            var line = "  " + pad(g.rawValue, 9) + style.temp(mx) + "  " + style.bar(mx / 100, width: 12, celsius: mx)
            if let avg, s.temperatures.filter({ $0.group == g && $0.known }).count > 1 {
                line += style.dim("  avg ") + style.temp(avg, width: 6)
            } else {
                line += String(repeating: " ", count: 12)
            }
            if let watts { line += "  " + pad(fmt(watts, "W", digits: 1), 8, right: true) }
            lines.append(line)
        }
        if lines.isEmpty { lines.append(style.dim("  no temperature sensors found")) }
        return [style.bold("Temperatures")] + lines
    }

    func temperatures(_ s: Snapshot) -> [String] {
        var lines = [style.bold("Temperatures")]
        let rows = s.temperatures.filter { showAll || $0.known }
        for g in SensorGroup.allCases {
            let items = rows.filter { $0.group == g }
            guard !items.isEmpty else { continue }
            lines.append("  " + style.cyan(g.rawValue))
            for r in items {
                let key = r.key.hasPrefix("hid:") ? "" : style.dim(pad(r.key, 5))
                lines.append("    " + pad(r.name, nameWidth) + key + style.temp(r.value)
                             + "  " + style.bar(r.value / 100, width: 10, celsius: r.value))
            }
        }
        if lines.count == 1 { lines.append(style.dim("  none")) }
        return lines
    }

    func fans(_ s: Snapshot) -> [String] {
        var lines = [style.bold("Fans")]
        if s.fans.isEmpty { return lines + [style.dim("  no fans (fanless Mac)")] }
        for f in s.fans {
            let mode = f.manual ? style.yellow("manual") : style.green("auto")
            let range = style.dim("[\(Int(f.min))–\(Int(f.max))]")
            lines.append("  " + pad("\(f.id) " + f.name, 10) + pad("\(Int(f.rpm.rounded())) rpm", 10, right: true)
                         + "  " + style.bar(f.load, width: 12) + pad(String(format: "%3.0f%%", f.load * 100), 5, right: true)
                         + "  " + range + "  " + mode
                         + (f.manual ? style.dim("  → \(Int(f.target ?? 0))") : ""))
        }
        return lines
    }

    func electrical(_ title: String, _ rows: [Reading], unit: String, digits: Int = 2) -> [String] {
        let items = rows.filter { showAll || $0.known }
        guard !items.isEmpty else { return [] }
        return [style.bold(title)] + items.map {
            "  " + pad($0.name, nameWidth) + style.dim(pad($0.key, 5)) + pad(fmt($0.value, unit, digits: digits), 10, right: true)
        }
    }

    func power(_ s: Snapshot) -> [String] {
        electrical("Power", s.power, unit: "W") + electrical("Voltage", s.voltages, unit: "V", digits: 3)
            + electrical("Current", s.currents, unit: "A", digits: 3)
    }

    func battery(_ b: BatteryInfo?) -> [String] {
        guard let b else { return [] }
        var parts: [String] = []
        if let p = b.percent { parts.append(String(format: "%.0f%%", p)) }
        parts.append(b.charging ? style.green("charging") : b.externalPower ? "on AC" : style.yellow("on battery"))
        if let t = b.temperature { parts.append(style.temp(t, width: 0)) }
        if let v = b.voltage { parts.append(String(format: "%.2f V", v)) }
        if let a = b.amperage { parts.append(String(format: "%+.2f A", a)) }
        if let w = b.power { parts.append(String(format: "%+.1f W", w)) }
        if let c = b.cycleCount { parts.append("\(c) cycles") }
        if let h = b.health { parts.append(String(format: "health %.0f%%", h * 100)) }
        return [style.bold("Battery"), "  " + parts.joined(separator: style.dim(" · "))]
    }

    func summaryPower(_ s: Snapshot) -> [String] {
        var parts: [String] = []
        if let w = s.systemPower { parts.append("system " + fmt(w, "W", digits: 1)) }
        if let w = s.cpuPower { parts.append("cpu " + fmt(w, "W", digits: 1)) }
        if let w = s.power.first(where: { $0.key == "PDTR" })?.value { parts.append("adapter " + fmt(w, "W", digits: 1)) }
        return parts.isEmpty ? [] : [style.bold("Power"), "  " + parts.joined(separator: style.dim(" · "))]
    }

    func summary(_ s: Snapshot) -> [String] {
        join([overview(s), fans(s), summaryPower(s), battery(s.battery)])
    }

    func join(_ sections: [[String]]) -> [String] {
        var out: [String] = []
        for sec in sections where !sec.isEmpty {
            if !out.isEmpty { out.append("") }
            out += sec
        }
        return out
    }
}

enum Export {
    static func json<T: Encodable>(_ v: T, pretty: Bool = true) -> String {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return (try? String(decoding: e.encode(v), as: UTF8.self)) ?? "{}"
    }

    static func csvField(_ s: String) -> String {
        s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    static func csvRows(_ rows: [Reading], kind: String) -> [String] {
        rows.map { [kind, $0.key, csvField($0.name), $0.group.rawValue, String(format: "%.3f", $0.value)].joined(separator: ",") }
    }

    static func csv(_ s: Snapshot, all: Bool) -> String {
        var lines = ["kind,key,name,group,value"]
        let f: (Reading) -> Bool = { all || $0.known }
        lines += csvRows(s.temperatures.filter(f), kind: "temperature")
        for fan in s.fans {
            lines.append("fan,F\(fan.id)Ac,\(csvField(fan.name)),Fan,\(String(format: "%.0f", fan.rpm))")
        }
        lines += csvRows(s.power.filter(f), kind: "power")
        lines += csvRows(s.voltages.filter(f), kind: "voltage")
        lines += csvRows(s.currents.filter(f), kind: "current")
        return lines.joined(separator: "\n")
    }

    /// Wide one-line-per-sample format for `watch --csv`.
    static func csvStreamHeader(_ s: Snapshot) -> String {
        (["timestamp", "cpu_c", "gpu_c", "hottest_c"] + s.fans.map { "fan\($0.id)_rpm" } + ["system_w", "cpu_w"])
            .joined(separator: ",")
    }

    static func csvStreamRow(_ s: Snapshot) -> String {
        func n(_ v: Double?, _ d: Int = 2) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "" }
        let ts = ISO8601DateFormatter().string(from: s.timestamp)
        return ([ts, n(s.cpu), n(s.gpu), n(s.hottest)] + s.fans.map { n($0.rpm, 0) } + [n(s.systemPower), n(s.cpuPower)])
            .joined(separator: ",")
    }
}
