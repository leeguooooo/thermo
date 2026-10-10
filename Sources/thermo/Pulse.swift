import CleanKit
import Foundation
import ThermoKit

/// `thermo pulse`: one answer to "how is this Mac doing / why is it slow" — for people and agents.
struct PulseCommand {
    let app: App

    /// What `--json` prints: the pulse plus the sensor headline numbers.
    struct Report: Encodable {
        let verdict: String
        let summary: String
        let culprit: String?
        let load1: Double
        let load5: Double
        let cores: Int
        let thermal: String
        let memory: String
        let swapUsedMB: Int
        let programs: [MachinePulse.Hog]
        let temperatures: [String: Double]
        let fans: [Fan]
        let systemPowerW: Double?
        let batteryPercent: Double?

        struct Fan: Encodable { let name: String; let rpm: Double; let min: Double; let max: Double; let manual: Bool }
    }

    func run() throws {
        let style = app.style
        let pulse = MachinePulse.sample()
        let sm = try? app.sampler()
        sm?.parts = [.temperatures, .fans, .power, .battery]
        let s = sm?.sample()

        if app.args.has("json") {
            var temps: [String: Double] = [:]
            if let v = s?.hottest { temps["hottest"] = v }
            if let v = s?.cpu { temps["cpu"] = v }
            if let v = s?.gpu { temps["gpu"] = v }
            print(Export.json(Report(
                verdict: pulse.verdict.rawValue, summary: pulse.verdictText, culprit: pulse.culpritText,
                load1: pulse.load1, load5: pulse.load5, cores: pulse.cores, thermal: pulse.thermal.rawValue,
                memory: pulse.memory.rawValue, swapUsedMB: pulse.swapUsedMB, programs: pulse.hogs, temperatures: temps,
                fans: (s?.fans ?? []).map { .init(name: $0.name, rpm: $0.rpm, min: $0.min, max: $0.max, manual: $0.manual) },
                systemPowerW: s?.systemPower, batteryPercent: s?.battery?.percent)))
            return
        }

        let mark = pulse.verdict == .ok ? style.green("✓") : pulse.verdict == .busy ? style.yellow("!") : style.red("!")
        var lines = [mark + " " + style.bold(pulse.verdictText)]
        if let c = pulse.culpritText { lines.append("  " + c) }
        lines.append(style.dim(String(format: "  load %.1f / %.1f (1 / 5 min) on %d cores · memory %@ · swap %d MB · thermal %@",
                                      pulse.load1, pulse.load5, pulse.cores, pulse.memory.rawValue, pulse.swapUsedMB,
                                      pulse.thermal.rawValue)))
        if !pulse.hogs.isEmpty {
            lines.append("")
            lines.append(style.bold("Busiest programs"))
            for h in pulse.hogs {
                let cpu = String(format: "%5.0f%%", h.cpu)
                lines.append("  " + (h.cpu >= 100 ? style.red(cpu) : h.cpu >= 50 ? style.yellow(cpu) : cpu)
                             + "  " + pad(h.memoryKB >= 1_048_576 ? String(format: "%.1f GB", Double(h.memoryKB) / 1_048_576) : "\(h.memoryKB / 1024) MB", 8, right: true)
                             + "  " + h.name + style.dim(h.pids.count > 1 ? "  (\(h.pids.count) processes)" : "  pid \(h.pids[0])")
                             + style.dim([h.project, h.owner.map { "started by " + $0 }].compactMap { $0 }.map { "  · " + $0 }.joined()))
            }
        }
        if let s {
            lines.append("")
            var sensors: [String] = []
            if let t = s.hottest { sensors.append("hottest " + style.temp(t, width: 0)) }
            if let t = s.cpu { sensors.append("CPU " + style.temp(t, width: 0)) }
            if let t = s.gpu { sensors.append("GPU " + style.temp(t, width: 0)) }
            if let w = s.systemPower { sensors.append(String(format: "%.1f W", w)) }
            lines.append("  " + sensors.joined(separator: style.dim(" · ")))
            for f in s.fans {
                lines.append("  " + f.name + "  \(Int(f.rpm)) rpm" + style.dim("  [\(Int(f.min))–\(Int(f.max))] " + (f.manual ? "manual" : "auto")))
            }
        }
        out(lines)
    }
}
