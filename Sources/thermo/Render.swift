import Foundation
import ThermoKit
import AgentDoctor

/// Text renderers. Each returns lines so `watch` can compose and trim them to the screen.
struct Renderer {
    var style: Style
    var showAll: Bool

    static func policyText(_ policy: FanPolicy?, available: Bool) -> String {
        available ? policy?.description ?? "auto" : "unknown"
    }

    static func controlText(_ state: FanControlState?, fan: Int) -> String {
        guard let state else { return "hardware verification unavailable" }
        let phase = state.verification(for: fan)
        guard phase == .checked, let observation = state.observations[fan] else { return "hardware verification: " + phase.rawValue }
        let target = observation.target.map { $0.isFinite ? String(format: "%.0f rpm", $0) : "unknown" } ?? ""
        return "last register check: \(observation.mode.rawValue) \(target) at \(observation.checkedAt.ISO8601Format())"
    }

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
        for g in SensorGroup.allCases {
            let items = s.temperatures.filter { $0.group == g && (showAll || $0.known) && $0.value.isFinite }
            guard let mx = items.map(\.value).max() else { continue }
            let watts: Double?
            switch g {
            case .cpu: watts = s.cpuPower
            case .gpu: watts = s.power.first { $0.key == "PCPG" || $0.key == "PG0R" }?.value
            default: watts = nil
            }
            var line = "  " + pad(g.rawValue, 9) + style.temp(mx) + "  " + style.bar(mx / 100, width: 12, celsius: mx)
            if items.count > 1 {
                let avg = items.reduce(0) { $0 + $1.value } / Double(items.count)
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
    static func pulseCSV<T: Encodable>(_ report: T) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(diagnosticJSON(report).utf8))) as? [String: Any] else { return "" }
        let units = ["load1": "load", "load5": "load", "cores": "count", "swapUsedMB": "MiB", "swapTotalMB": "MiB", "diskFreeBytes": "B",
                     "systemPowerW": "W", "batteryPercent": "%", "records": "count", "strugglingRecords": "count",
                     "peakLoad": "load", "peakSwapMB": "MiB"]
        func cell(_ value: Any) -> String {
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        var rows = ["kind,name,value,unit"]
        func append(_ kind: String, _ name: String, _ value: Any, _ unit: String) {
            rows.append([kind, name, cell(value), unit].map(csvField).joined(separator: ","))
        }
        for key in object.keys.sorted() {
            guard let value = object[key] else { continue }
            if key == "temperatures", let temperatures = value as? [String: Any] {
                for (name, temperature) in temperatures.sorted(by: { $0.key < $1.key }) { append("temperature", name, temperature, "°C") }
            } else if let values = value as? [Any] {
                for (index, entry) in values.enumerated() {
                    let name = (entry as? [String: Any])?["name"] as? String ?? String(index)
                    append(key == "programs" ? "program" : key == "fans" ? "fan" : key, name, entry,
                           entry is String ? "" : "JSON")
                }
            } else { append("system", key, value, value is [String: Any] ? "JSON" : units[key] ?? "") }
        }
        return rows.joined(separator: "\n")
    }

    static func diagnosticCSV(items: [AgentItem], findings: [Finding], generated: Date) -> String {
        struct Payload: Encodable { let items: [AgentItem]; let findings: [Finding] }
        let safe = diagnosticJSON(Payload(items: items, findings: findings))
        guard let object = (try? JSONSerialization.jsonObject(with: Data(safe.utf8))) as? [String: Any],
              let itemRows = object["items"] as? [[String: Any]],
              let findingRows = object["findings"] as? [[String: Any]] else { return "" }
        let columns = ["kind", "generated", "id", "area", "agent", "name", "enabled", "severity", "detail", "source", "fix", "findings", "actions"]
        let timestamp = ISO8601DateFormatter().string(from: generated)
        func text(_ row: [String: Any], _ key: String) -> String { row[key] as? String ?? "" }
        func jsonCell(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        var rows = [columns.joined(separator: ",")]
        let ids = Set(itemRows.map { text($0, "id") })
        for item in itemRows {
            let related = findingRows.filter { text($0, "item") == text(item, "id") }
            let values = ["item", timestamp, text(item, "id"), text(item, "area"), text(item, "agent"), text(item, "name"),
                          (item["enabled"] as? Bool).map { $0 ? "true" : "false" } ?? "", text(item, "severity"),
                          text(item, "detail"), text(item, "source"), "", jsonCell(related), jsonCell(item["actions"] ?? [])]
            rows.append(values.map(csvField).joined(separator: ","))
        }
        for finding in findingRows where !ids.contains(text(finding, "item")) {
            rows.append(["finding", timestamp, "", text(finding, "area"), text(finding, "agent"), text(finding, "subject"), "",
                         text(finding, "severity"), text(finding, "message"), text(finding, "source"), text(finding, "fix"), "", ""]
                .map(csvField).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    static func settingsCSV(_ values: [(key: String, value: String)]) -> String {
        (["key,value"] + values.map { [csvField($0.key), csvField($0.value)].joined(separator: ",") }).joined(separator: "\n")
    }
    static func diagnosticJSON<T: Encodable>(_ value: T) -> String {
        let raw = json(value)
        guard let safe = try? Redact.jsonExport(Data(raw.utf8)) else { return "{}" }
        return String(decoding: safe, as: UTF8.self)
    }
    static func fanStatusCSV(_ fans: [FanReading], policies: [Int: FanPolicy], helperNote: String?, controlState: FanControlState? = nil) -> String {
        let available = helperNote == nil
        let columns = ["id", "name", "rpm", "min_rpm", "max_rpm", "target_rpm", "manual", "policy", "verification_state", "last_observed_mode", "verified_target_rpm", "checked_at", "policies_suspended", "control_failure", "policies_available", "helper"]
        func number(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "" }
            return String(format: "%.3f", value)
        }
        func verification(_ id: Int) -> [String] {
            let observation = controlState?.observations[id]
            let checked = observation.flatMap { $0.checkedAt.timeIntervalSince1970.isFinite ? $0.checkedAt.ISO8601Format() : nil }
            return [controlState?.verification(for: id).rawValue ?? "unavailable", observation?.mode.rawValue ?? "",
                    number(observation?.target), checked ?? "",
                    controlState.map { $0.suspended ? "true" : "false" } ?? "", controlState?.failure ?? ""]
        }
        var rows = fans.map { fan in
            [String(fan.id), fan.name, number(fan.rpm), number(fan.min), number(fan.max), number(fan.target),
             fan.manual ? "true" : "false", Renderer.policyText(policies[fan.id], available: available)]
             + verification(fan.id) + [available ? "true" : "false", helperNote ?? "running"]
        }
        // Preserve helper status even on fanless machines.
        if rows.isEmpty { rows = [Array(repeating: "", count: 8) + verification(-1) + [available ? "true" : "false", helperNote ?? "running"]] }
        return ([columns.joined(separator: ",")] + rows.map { $0.map(csvField).joined(separator: ",") }).joined(separator: "\n")
    }

    static func helperStatusCSV(_ fields: [String: String]) -> String {
        let columns = ["installed", "running", "version", "installationSource"]
        return columns.joined(separator: ",") + "\n" + columns.map { csvField(fields[$0] ?? "") }.joined(separator: ",")
    }

    static func keyReadCSV(_ rows: [[String: String]]) -> String {
        let columns = ["key", "type", "value", "hex", "error"]
        return ([columns.joined(separator: ",")] + rows.map { row in
            columns.map { csvField(row[$0] ?? "") }.joined(separator: ",")
        }).joined(separator: "\n")
    }

    static func json<T: Encodable>(_ v: T, pretty: Bool = true) -> String {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return (try? String(decoding: e.encode(v), as: UTF8.self)) ?? "{}"
    }

    static func csvField(_ s: String) -> String {
        s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")
            ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    static func csvRows(_ rows: [Reading], kind: String) -> [String] {
        rows.map { [kind, $0.key, $0.name, $0.group.rawValue, String(format: "%.3f", $0.value)].map(csvField).joined(separator: ",") }
    }

    static func batteryRows(_ battery: BatteryInfo) -> [String] {
        let values: [(String, String, Double?)] = [
            ("charge_percent", "Charge (%)", battery.percent),
            ("temperature_c", "Temperature (C)", battery.temperature),
            ("voltage_v", "Voltage (V)", battery.voltage),
            ("current_a", "Current (A)", battery.amperage),
            ("power_w", "Power (W)", battery.power),
            ("cycles", "Cycles", battery.cycleCount.map(Double.init)),
            ("health_percent", "Health (%)", battery.health.map { $0 * 100 }),
            ("charging", "Charging (0/1)", battery.charging ? 1 : 0),
            ("external_power", "External power (0/1)", battery.externalPower ? 1 : 0),
        ]
        return values.compactMap { key, name, value in
            guard let value, value.isFinite else { return nil }
            return ["battery", key, name, "Battery", String(format: "%.3f", value)]
                .map(csvField).joined(separator: ",")
        }
    }

    static func csv(_ battery: BatteryInfo) -> String {
        (["kind,key,name,group,value"] + batteryRows(battery)).joined(separator: "\n")
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
        if let battery = s.battery { lines += batteryRows(battery) }
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
        return ([ts, n(s.cpu), n(s.gpu), n(s.maximumKnownTemperature)] + s.fans.map { n($0.rpm, 0) } + [n(s.systemPower), n(s.cpuPower)])
            .joined(separator: ",")
    }
}
