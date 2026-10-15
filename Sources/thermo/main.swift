import CleanKit
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
  agents fix [--dry-run]     apply every safe automatic fix (shows the plan, asks first;
                             --yes to skip the question)
  agents show NAME           one item: problems, suggestions and numbered actions
  agents fix|uninstall|disable NAME
                             that action on one item (--area/--agent to narrow,
                             --all for every match)
  agents run NAME --action N any action listed by `agents show`
  agents list [AREA]         everything checked, each marked OK or not; AREA is
                             hooks, mcp, plugins, skills, statusline, launchd
                             or processes
  activity [--json]          whole-machine and per-program CPU/GPU readings
  memory                    program memory by app/tool, with project and process details (--json)
  pulse                      why is this Mac slow: verdict, busiest programs, load,
                             memory, thermal state, temperatures, fans (--json for agents)
  pulse quit NAME|PID         stop a program pulse lists (apps quit like ⌘Q); asks first
  pulse restart NAME          quit an app, wait, reopen it (frees what a long-running app piled up)
  pulse history [--since 6h]  who slowed the Mac down lately (recorded by Thermo.app; 1h, 6h, 24h)
  pulse chrome [--watch 60]   which Chrome page leaks or is biggest, duplicate tabs, hidden pages
                              (memory per page needs chrome-use; --app "Microsoft Edge" for others)
  pulse chrome close URL      close one tab showing URL (--title to pick); asks first
  tabs list|groups           tabs, Thermo groups and protection reasons (--app BROWSER)
  tabs group NAME --ids IDS  create a Thermo group; --by-site resets grouping to websites
  tabs archive               save and close unprotected background tabs in the front window
                             --group NAME / --ids IDS / --window ID / --all-windows
                             --name NAME, --dry-run to review, --yes to execute
  tabs organize --dry-run    preview native Chrome groups; --yes applies website/custom rules
  tabs auto [on|off]         opt-in automatic native grouping every minute while the app runs
  tabs rule [add DOMAIN NAME|remove UUID]  grouping rules (--color COLOR)
  tabs organized             grouping history; tabs undo-organize UUID --yes undoes a batch
  tabs saved|show UUID       saved batches and individual close/restore results
  tabs restore UUID          reopen a saved batch in its original window; --window ID
                             explicitly selects a destination after a browser restart
  history                    every change Thermo made (cleanups, uninstalls, agent fixes, Claude reset,
                             privacy, tabs, archives, quits), newest first, and where each is undone;
                             --limit N, --json; history show ID for every item
  settings [KEY [VALUE]]     the app's settings: menu bar text, interval, alerts, units,
                             language, Dock icon (KEY=VALUE also works)
  clean [CATEGORY|ai]        what can be cleaned: AI sessions/models/caches, dev caches,
                             Xcode, project build output, browsers (read-only)
  clean run safe|ID…         remove items (safe: delete; review files: Trash); asks first
                             --dry-run shows the plan without deleting or running commands
  clean empty-trash BATCH    review this batch with --dry-run; --yes permanently removes only its Trash items
  clean restore BATCH        move this batch's Trash items back where they were (--dry-run first;
                             never overwrites anything now at the original path)
  clean log                  what earlier cleanups removed
  clean overview             where the used space is: the big places and their
                             biggest folders (--json)
  apps                       installed apps, their size and the files they keep in your home folder
  apps uninstall NAME        move the app and its files to the Trash (lists every path, asks first;
                             --dry-run only lists; refuses running, system and protected apps;
                             browser, chat and mail data stays unless --with-data)
  space [PATH]               what takes the space in a folder, biggest first (one walk, kept an hour)
  space large                files over 100 MB and when they were last opened (--older-than DAYS)
  space dupes [PATH…]        identical files (default: Desktop, Documents, Downloads, media folders)
  space trash PATH…          move picked files or folders to the Trash (lists them, asks first)
  space archive PATH         verified SSH/tar archive; --to nas:/archive/name.tar
                             --remove-local removes originals only after verification;
                             installed development environments need --inactive-development
  apps leftovers             data left by apps that are gone (untouched 30 days, unknown to Spotlight)
  apps leftovers remove ID…|all
                             move that data to the Trash; asks first

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
      --budget SECONDS       clean: stop read-only scan after this budget; mark results incomplete
      --stream               clean: incremental JSON events, one per line (read-only)
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
        case "apps", "app": try AppsCommand(app: self).run(rest)
        case "space": try SpaceCommand(app: self).run(rest)
        case "memory": try MemoryCommand(app: self).run(rest)
        case "activity": try ComputeCommand(app: self).run(rest)
        case "pulse", "status": try PulseCommand(app: self).run(rest)
        case "tabs": try TabsCommand(app: self).run(rest)
        case "settings", "config": try SettingsCommand(app: self).run(rest)
        case "history": try HistoryCommand(app: self).run(rest)
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
        if args.has("csv") { print(Export.csv(b)); return }
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
                if args.has("json") || args.has("csv") {
                    rows.append(["key": k, "type": v.type.description, "value": v.display, "hex": v.hex])
                } else {
                    print(style.bold(pad(k, 6)) + style.dim(pad(v.type.description, 6)) + v.display + style.dim("  [\(v.hex)]"))
                }
            } catch {
                failed = true
                if args.has("json") || args.has("csv") { rows.append(["key": k, "error": "\(error)"]) }
                else { FileHandle.standardError.write("thermo: \(error)\n".data(using: .utf8)!) }
            }
        }
        if args.has("json") { print(Export.json(rows)) }
        else if args.has("csv") { print(Export.keyReadCSV(rows)) }
        if failed { exit(1) }
    }

    // MARK: fan

    static func fanRPM(_ input: String) throws -> Double {
        switch input.lowercased() {
        case "max": return .infinity
        case "min": return 0
        default:
            guard let rpm = Double(input), rpm.isFinite, rpm >= 0 else {
                throw CLIError("RPM must be a finite nonnegative number, 'min' or 'max'")
            }
            return rpm
        }
    }

    static func fanRPMText(_ rpm: Double) -> String {
        rpm.isInfinite ? "max" : rpm == 0 ? "min" : String(format: "%g rpm", rpm)
    }

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
            catch { helperNote = "helper unavailable (thermo helper status)" }
            if args.has("json") {
                struct Status: Encodable { let fans: [FanReading]; let policies: [String: FanPolicy]; let helper: String?; let policiesAvailable: Bool }
                print(Export.json(Status(fans: s.fans,
                                         policies: Dictionary(uniqueKeysWithValues: policies.map { (String($0.key), $0.value) }),
                                         helper: helperNote, policiesAvailable: helperNote == nil)))
                return
            }
            if args.has("csv") { print(Export.fanStatusCSV(s.fans, policies: policies, helperNote: helperNote)); return }
            out(renderer.fans(s))
            print("")
            print(style.bold("Policies"))
            for f in s.fans { print("  " + pad("\(f.id) " + f.name, 10) + Renderer.policyText(policies[f.id], available: helperNote == nil)) }
            if let helperNote { print(style.dim("  " + helperNote)) }

        case "set":
            guard rest.count == 3 else { throw CLIError("usage: thermo fan set ID|all RPM|max") }
            let rpm = try Self.fanRPM(rest[2])
            for id in try fanTargets(rest[1], fans: sm.fans) {
                try client.blocking(timeout: 15) { try await $0.setPolicy(.fixed(rpm: rpm), fan: id) }
            }
            warnClamp(rpm, sm: sm)
            print("fan \(rest[1]): fixed \(Self.fanRPMText(rpm))")

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

    static func helperStatusFields(legacyInstalled: Bool, version: String?) -> [String: String] {
        ["installed": legacyInstalled || version != nil ? "true" : "false",
         "running": version != nil ? "true" : "false", "version": version ?? "",
         "installationSource": legacyInstalled ? "legacy" : version != nil ? "connected" : "unknown"]
    }

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
            let fields = Self.helperStatusFields(legacyInstalled: installed, version: v)
            if args.has("json") {
                print(Export.json(fields))
                return
            }
            if args.has("csv") { print(Export.helperStatusCSV(fields)); return }
            // Thermo.app registers the helper via SMAppService (no files in /Library); only the legacy install is visible on disk.
            print("installed: " + (installed ? style.green("yes (/Library/PrivilegedHelperTools)")
                                   : v != nil ? style.green("yes (Thermo.app background item)") : style.yellow("not detected; background registration unknown")))
            let current = v == HelperConstants.version
            print("running:   " + (v == nil ? style.yellow("no") : current ? style.green("yes (\(v!))")
                                   : style.yellow("yes, outdated (\(v!); this thermo is \(HelperConstants.version)) — run: thermo helper install")))
            print("client signed by: " + (CodeSignature.teamIdentifier().map { "team \($0)" } ?? style.yellow("ad-hoc (production helpers may reject this client)")))
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
        var measurements: [BenchmarkReport.Measurement] = []
        func row(_ label: String, _ t: (wall: Double, cpu: Double), _ note: String = "", samples: Int = 1, records: Int? = nil) -> String {
            measurements.append(.init(name: label, samples: samples, wallMs: t.wall, cpuMs: t.cpu, returnedRecords: records))
            return "  " + pad(label, 26) + String(format: "%9.3f ms %9.3f ms", t.wall, t.cpu) + style.dim(note)
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
            row("full key scan", scan, "  \(d.sensors.count) SMC sensor keys, \(d.fans.count) fans"),
            row("init (cache allowed)", cached),
        ]
        let n = 100
        for (scope, label) in [(SamplerScope.essential, "essential"), (.known, "known"), (.all, "all")] {
            sm.scope = scope
            var sample: Snapshot?
            let t = time(n) { sample = sm.sample() }
            let records = sample.map(BenchmarkReport.recordCount) ?? 0
            lines.append(row("sample (\(label))", t, "  \(records) returned records", samples: n, records: records))
        }
        lines.append(row("battery (IORegistry)", time(20) { _ = Battery.read() }, samples: 20))
        sm.scope = .essential
        let e = time(n) { _ = sm.sample() }
        measurements.append(.init(name: "background sampling (essential)", samples: n, wallMs: e.wall, cpuMs: e.cpu, returnedRecords: nil))
        lines.append(style.dim(String(format: "  estimated sampling CPU at 2 s interval (essential): %.2f%% of one core", e.cpu / 2000 * 100)))
        // The slowdown history: one incremental pulse pass a minute (five on battery), plus the write.
        let pulseSampler = PulseSampler()
        _ = pulseSampler.sample()  // the first pass measures over a short window; steady state is what runs
        let history = PulseHistory(url: FileManager.default.temporaryDirectory.appendingPathComponent("thermo-bench-\(UUID().uuidString).jsonl"))
        let pt = time(10) { history.append(PulseRecord(pulseSampler.sample())) }
        try? FileManager.default.removeItem(at: history.url)
        lines.append(row("pulse history tick", pt, samples: 10))
        lines.append(style.dim(String(format: "  estimated history CPU at 60 s interval: %.3f%% of one core (300 s on battery: %.3f%%)",
                                      pt.cpu / 60_000 * 100, pt.cpu / 300_000 * 100)))
        let report = BenchmarkReport(model: d.model, smcKeys: d.keyCount, smcSensors: d.sensors.count, fans: d.fans.count,
            measurements: measurements, estimates: [
                .init(name: "essential sampling", intervalSeconds: 2, cpuPercent: e.cpu / 2000 * 100),
                .init(name: "pulse history", intervalSeconds: 60, cpuPercent: pt.cpu / 60_000 * 100),
                .init(name: "pulse history (battery)", intervalSeconds: 300, cpuPercent: pt.cpu / 300_000 * 100),
            ])
        if args.has("json") { print(Export.json(report)); return }
        if args.has("csv") { print(report.csv); return }
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
