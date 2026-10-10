import Foundation
import ThermoKit
import ThermoL10n

let thermoVersion = ThermoVersion.string

let usage = """
thermo \(thermoVersion) — temperatures, fans and power for macOS

USAGE
  thermo [command] [options]

COMMANDS
  (none)                     overview: hottest sensors, fans, power, battery
  temps                      every temperature sensor, grouped
  fans                       fan speeds, limits and mode
  power                      power (W), voltage (V) and current (A)
  battery                    battery temperature, charge, health
  watch                      live full-screen view (q to quit)
  list                       raw SMC keys with type, size and value
  get KEY [KEY...]           read raw SMC keys
  fan status                 fan policies held by the helper
  fan set ID|all RPM|max     fixed fan speed (needs helper)
  fan curve ID|all CURVE     temperature curve, e.g. 50:min,70:3000,85:max
  fan auto [ID|all]          return fans to automatic control
  helper install|uninstall|status
  bench                      measure sampling latency
  agents                     diagnose AI agents: hooks, MCP servers, plugins,
                             skills, launch agents and leaked processes
                             (Claude Code, Codex, Cursor, Gemini; read-only)
  agents fix [NAME]          apply the automatic fixes, or one item's (shows the plan, asks first;
                             --yes to skip the question)
  agents list [AREA]         everything checked, each marked OK or not; AREA is
                             hooks, mcp, plugins, skills, statusline, launchd
                             or processes
  pulse                      why is this Mac slow: verdict, busiest programs, load,
                             memory, thermal state, temperatures, fans (--json for agents)
  clean [CATEGORY|ai]        what can be cleaned: AI sessions/models/caches, dev caches,
                             Xcode, project build output, browsers (read-only)
  clean run safe|ID…         remove items (safe: delete; review: to Trash); asks first
  clean log                  what earlier cleanups removed

OPTIONS
  -a, --all                  include sensors without a known name
                             (agents: also show notes and config sources)
  -j, --json                 JSON output (watch: one object per line)
      --csv                  CSV output (watch: one row per sample)
  -i, --interval SEC         watch interval (default 1)
  -n, --count N              watch: stop after N samples
  -s, --sensor cpu|gpu|max   sensor driving a fan curve (default cpu)
      --fahrenheit           show °F
      --no-color             disable colors (also honours NO_COLOR)
      --no-cache             rescan SMC keys instead of using the discovery cache
      --older-than DAYS      clean: sessions/projects idle this long are stale (default 30; 2w, 6m)
      --root DIR[,DIR]       clean: folders searched for projects (default ~/Developer, ~/code, …)
  -y, --yes                  clean run: do not ask for confirmation
      --trash | --permanent  clean run: send everything to the Trash / delete everything
  -h, --help                 this help
  -v, --version              version
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(("thermo: " + message + "\n").data(using: .utf8)!)
    exit(code)
}

func out(_ lines: [String]) { print(lines.joined(separator: "\n")) }

// MARK: - Commands

struct App {
    let args: Args
    var style: Style
    var renderer: Renderer { Renderer(style: style, showAll: args.has("all")) }

    init(args: Args) {
        self.args = args
        var s = Style.detect(noColor: args.has("no-color"))
        s.fahrenheit = args.has("fahrenheit")
        style = s
    }

    func sampler() throws -> Sampler {
        try Sampler(scope: args.has("all") ? .all : .known, useCache: !args.has("no-cache"))
    }

    func run() throws {
        if args.has("version") { print("thermo \(thermoVersion)"); return }
        let cmd = args.positionals.first ?? ""
        let rest = Array(args.positionals.dropFirst())
        if args.has("help") || cmd == "help" { print(usage); return }

        switch cmd {
        case "": try snapshotCommand([.temperatures, .fans, .power, .battery], header: true) { r, s in r.summary(s) }
        case "temps", "temp", "t": try snapshotCommand(.temperatures) { r, s in r.temperatures(s) }
        case "fans", "f": try snapshotCommand(.fans) { r, s in r.fans(s) }
        case "power", "p": try snapshotCommand([.power, .electrical]) { r, s in r.power(s) }
        case "battery", "b": try batteryCommand()
        case "watch", "w": try Watch(app: self).run()
        case "list", "ls": try listCommand()
        case "get": try getCommand(rest)
        case "fan": try fanCommand(rest)
        case "helper": try helperCommand(rest)
        case "bench": try benchCommand()
        case "agents", "agent", "doctor": try AgentsCommand(app: self).run(rest)
        case "clean": try CleanCommand(app: self).run(rest)
        case "pulse", "status": try PulseCommand(app: self).run()
        default: throw CLIError("unknown command '\(cmd)' (see thermo --help)")
        }
    }

    func snapshotCommand(_ parts: SamplerParts, header: Bool = false,
                         render: (Renderer, Snapshot) -> [String]) throws {
        let sm = try sampler()
        // JSON/CSV of the overview export everything that was asked for.
        sm.parts = header && (args.has("json") || args.has("csv")) ? .everything : parts
        let s = sm.sample()
        if args.has("json") {
            print(Export.json(filtered(s)))
        } else if args.has("csv") {
            print(Export.csv(s, all: args.has("all")))
        } else {
            let header = header ? renderer.header(s, model: sm.discovery.model) + [""] : []
            out(header + render(renderer, s))
        }
    }

    func filtered(_ s: Snapshot) -> Snapshot {
        guard !args.has("all") else { return s }
        return Snapshot(timestamp: s.timestamp, temperatures: s.temperatures.filter(\.known), fans: s.fans,
                        power: s.power.filter(\.known), voltages: s.voltages.filter(\.known),
                        currents: s.currents.filter(\.known), battery: s.battery)
    }

    func batteryCommand() throws {
        guard let b = Battery.read() else { throw CLIError("no battery found") }
        if args.has("json") { print(Export.json(b)); return }
        out(renderer.battery(b))
    }

    func listCommand() throws {
        let smc = try SMC()
        let keys = try smc.allKeys()
        var rows: [[String: String]] = []
        var lines: [String] = []
        for k in keys {
            guard let info = try? smc.info(k) else { continue }
            let value = try? smc.read(k)
            if args.has("json") {
                rows.append(["key": k.description, "type": info.type.description, "size": String(info.size),
                             "value": value?.display ?? "", "hex": value?.hex ?? ""])
            } else if args.has("csv") {
                lines.append([Export.csvField(k.description), info.type.description, String(info.size),
                              Export.csvField(value?.display ?? "")].joined(separator: ","))
            } else {
                lines.append(style.bold(pad(k.description, 6)) + style.dim(pad(info.type.description, 6) + pad(String(info.size), 4, right: true))
                             + "  " + (value?.display ?? style.dim("(unreadable)")))
            }
        }
        if args.has("json") { print(Export.json(rows)); return }
        if args.has("csv") { lines.insert("key,type,size,value", at: 0) }
        out(lines)
        if !args.has("csv") { print(style.dim("\(keys.count) keys")) }
    }

    func getCommand(_ keys: [String]) throws {
        guard !keys.isEmpty else { throw CLIError("usage: thermo get KEY [KEY...]") }
        let smc = try SMC()
        var rows: [[String: String]] = []
        var failed = false
        for k in keys {
            guard k.utf8.count <= 4 else { throw CLIError("'\(k)' is not a 4-character SMC key") }
            do {
                let v = try smc.read(FourCC(k))
                if args.has("json") {
                    rows.append(["key": k, "type": v.type.description, "value": v.display, "hex": v.hex])
                } else {
                    print(style.bold(pad(k, 6)) + style.dim(pad(v.type.description, 6)) + v.display + style.dim("  [\(v.hex)]"))
                }
            } catch {
                failed = true
                if args.has("json") { rows.append(["key": k, "error": "\(error)"]) }
                else { FileHandle.standardError.write("thermo: \(error)\n".data(using: .utf8)!) }
            }
        }
        if args.has("json") { print(Export.json(rows)) }
        if failed { exit(1) }
    }

    // MARK: fan

    func fanTargets(_ spec: String?, fans: [FanDescriptor]) throws -> [Int] {
        guard let spec, spec != "all" else { return [-1] }
        guard let id = Int(spec), fans.contains(where: { $0.index == id }) else {
            throw CLIError("unknown fan '\(spec)'; fans: " + fans.map { "\($0.index) (\($0.name))" }.joined(separator: ", "))
        }
        return [id]
    }

    func fanCommand(_ rest: [String]) throws {
        let sub = rest.first ?? "status"
        let sm = try sampler()
        let client = HelperClient()

        switch sub {
        case "status":
            let s = sm.sample()
            var policies: [Int: FanPolicy] = [:]
            var helperNote: String?
            do { policies = try client.blocking(timeout: 2) { try await $0.policies() } }
            catch { helperNote = HelperInstaller.isInstalled ? "helper not responding" : "helper not installed (thermo helper install)" }
            if args.has("json") {
                struct Status: Encodable { let fans: [FanReading]; let policies: [String: FanPolicy]; let helper: String? }
                print(Export.json(Status(fans: s.fans,
                                         policies: Dictionary(uniqueKeysWithValues: policies.map { (String($0.key), $0.value) }),
                                         helper: helperNote)))
                return
            }
            out(renderer.fans(s))
            print("")
            print(style.bold("Policies"))
            for f in s.fans { print("  " + pad("\(f.id) " + f.name, 10) + (policies[f.id]?.description ?? "auto")) }
            if let helperNote { print(style.dim("  " + helperNote)) }

        case "set":
            guard rest.count == 3 else { throw CLIError("usage: thermo fan set ID|all RPM|max") }
            let rpm: Double = rest[2].lowercased() == "max" ? .infinity : (rest[2].lowercased() == "min" ? 0 : (Double(rest[2]) ?? -1))
            guard rpm >= 0 else { throw CLIError("RPM must be a number, 'min' or 'max'") }
            for id in try fanTargets(rest[1], fans: sm.fans) {
                try client.blocking(timeout: 15) { try await $0.setPolicy(.fixed(rpm: rpm), fan: id) }
            }
            warnClamp(rpm, sm: sm)
            print("fan \(rest[1]): fixed \(rpm.isInfinite ? "max" : rpm == 0 ? "min" : "\(Int(rpm)) rpm")")

        case "curve":
            guard rest.count == 3 else { throw CLIError("usage: thermo fan curve ID|all 50:min,70:3000,85:max [--sensor cpu|gpu|max]") }
            let sensor = try CurveSensor(rawValue: args.options["sensor"] ?? "cpu")
                .orThrow(CLIError("--sensor must be cpu, gpu or max"))
            let curve = try FanCurve(parsing: rest[2], sensor: sensor)
            for id in try fanTargets(rest[1], fans: sm.fans) {
                try client.blocking(timeout: 15) { try await $0.setPolicy(.curve(curve), fan: id) }
            }
            print("fan \(rest[1]): curve \(curve.description)")

        case "auto":
            for id in try fanTargets(rest.count > 1 ? rest[1] : "all", fans: sm.fans) {
                try client.blocking(timeout: 15) { try await $0.setPolicy(.auto, fan: id) }
            }
            print("fan \(rest.count > 1 ? rest[1] : "all"): auto")

        default:
            throw CLIError("unknown fan command '\(sub)' (status, set, curve, auto)")
        }
    }

    func warnClamp(_ rpm: Double, sm: Sampler) {
        guard rpm.isFinite, rpm > 0 else { return }
        for f in sm.sample().fans where rpm < f.min || rpm > f.max {
            FileHandle.standardError.write("thermo: note: \(f.name) is limited to \(Int(f.min))–\(Int(f.max)) rpm; value clamped\n".data(using: .utf8)!)
        }
    }

    // MARK: helper

    func helperCommand(_ rest: [String]) throws {
        switch rest.first ?? "status" {
        case "install":
            guard let bin = HelperInstaller.locateHelperBinary() else {
                throw CLIError("thermo-helper binary not found next to thermo or in /Applications/Thermo.app")
            }
            print("Installing helper from \(bin.path) (administrator password required)…")
            try HelperInstaller.install(from: bin)
            let v = try? HelperClient().blocking(timeout: 5) { try await $0.version() }
            print(v != nil ? style.green("helper installed and running") : style.yellow("helper installed; not responding yet"))
        case "uninstall":
            try HelperInstaller.uninstall()
            print("helper removed; fans returned to automatic control")
        case "status":
            let installed = HelperInstaller.isInstalled
            let v = try? HelperClient().blocking(timeout: 2) { try await $0.version() }
            if args.has("json") {
                print(Export.json(["installed": installed ? "true" : "false", "running": v != nil ? "true" : "false", "version": v ?? ""]))
                return
            }
            // Thermo.app registers the helper via SMAppService (no files in /Library); only the legacy install is visible on disk.
            print("installed: " + (installed ? style.green("yes (/Library/PrivilegedHelperTools)")
                                   : v != nil ? style.green("yes (Thermo.app background item)") : style.yellow("no")))
            let current = v == HelperConstants.version
            print("running:   " + (v == nil ? style.yellow("no") : current ? style.green("yes (\(v!))")
                                   : style.yellow("yes, outdated (\(v!); this thermo is \(HelperConstants.version)) — run: thermo helper install")))
            print("signed by: " + (CodeSignature.teamIdentifier().map { "team \($0)" } ?? style.yellow("ad-hoc (helper accepts any client with the right identifier)")))
        default:
            throw CLIError("usage: thermo helper install|uninstall|status")
        }
    }

    // MARK: bench

    func benchCommand() throws {
        func clock() -> (wall: Double, cpu: Double) {
            var ru = rusage()
            getrusage(RUSAGE_SELF, &ru)
            let cpu = Double(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1e3
                + Double(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e3
            return (Double(DispatchTime.now().uptimeNanoseconds) / 1e6, cpu)
        }
        func time(_ n: Int = 1, _ body: () throws -> Void) rethrows -> (wall: Double, cpu: Double) {
            let a = clock()
            for _ in 0..<n { try body() }
            let b = clock()
            return ((b.wall - a.wall) / Double(n), (b.cpu - a.cpu) / Double(n))
        }
        func row(_ label: String, _ t: (wall: Double, cpu: Double), _ note: String = "") -> String {
            "  " + pad(label, 26) + String(format: "%9.3f ms %9.3f ms", t.wall, t.cpu) + style.dim(note)
        }

        var smc: SMC!
        let open = try time { smc = try SMC() }
        var d: Discovery!
        let scan = try time { d = try Sampler.discover(smc: smc) }
        var sm: Sampler!
        let cached = try time { sm = try Sampler(scope: .known) }
        sm.parts = [.temperatures, .fans, .power, .electrical]
        _ = sm.sample()

        var lines = [
            style.bold("thermo bench") + style.dim(" · \(d.model) · \(d.keyCount) SMC keys"),
            "  " + pad("", 26) + style.dim("     wall        cpu"),
            row("open SMC", open),
            row("full key scan", scan, "  \(d.sensors.count) sensors, \(d.fans.count) fans"),
            row("init from cache", cached),
        ]
        let n = 100
        for (scope, label, filter) in [(SamplerScope.essential, "essential", { (s: SensorDescriptor) in s.essential }),
                                       (.known, "known", { $0.known }), (.all, "all", { _ in true })] {
            sm.scope = scope
            let t = time(n) { _ = sm.sample() }
            let keys = d.sensors.filter(filter).count + d.fans.count * 2
            lines.append(row("sample (\(label))", t, String(format: "  %d keys, %.0f µs/key", keys, t.wall * 1000 / Double(max(1, keys)))))
        }
        lines.append(row("battery (IORegistry)", time(20) { _ = Battery.read() }))
        sm.scope = .essential
        let e = time(n) { _ = sm.sample() }
        lines.append(style.dim(String(format: "  background cost at 2 s interval (essential): %.2f%% of one core", e.cpu / 2000 * 100)))
        out(lines)
    }
}

extension Optional {
    func orThrow(_ e: Error) throws -> Wrapped {
        guard let v = self else { throw e }
        return v
    }
}

// MARK: - main

setvbuf(stdout, nil, _IOFBF, 1 << 16)
// Scripts and logs parse CLI output, so it stays English unless THERMO_LANG asks otherwise.
if ProcessInfo.processInfo.environment["THERMO_LANG"] == nil { L10n.override = .english }
do {
    let args = try Args(Array(CommandLine.arguments.dropFirst()))
    try App(args: args).run()
    fflush(stdout)
} catch let e as CLIError {
    fflush(stdout)
    fail(e.description, code: 2)
} catch {
    fflush(stdout)
    fail("\(error)")
}
