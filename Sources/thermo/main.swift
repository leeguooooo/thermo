import CleanKit
import AgentCore
import Foundation
import ThermoKit
import ThermoL10n

let thermoVersion = ThermoVersion.string


func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(("thermo: " + message + "\n").data(using: .utf8)!)
    exit(code)
}

func out(_ lines: [String]) { print(lines.joined(separator: "\n")) }

// MARK: - Commands

struct App {
    struct VersionReport: Encodable {
        let schemaVersion = 1
        let cliVersion: String
        let appPackage: AppBuildMetadata?
        enum CodingKeys: CodingKey { case schemaVersion, cliVersion, appPackage }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(schemaVersion, forKey: .schemaVersion)
            try c.encode(cliVersion, forKey: .cliVersion)
            if let appPackage { try c.encode(appPackage, forKey: .appPackage) }
            else { try c.encodeNil(forKey: .appPackage) }
        }
    }
    static func versionReport(executable: URL? = ProcessTable.pidPath(getpid()).map { URL(fileURLWithPath: $0) }) -> VersionReport {
        VersionReport(cliVersion: ThermoVersion.string, appPackage: AppBuildMetadata.containingCLI(executable: executable))
    }
    let args: Args
    var style: Style
    var renderer: Renderer { Renderer(style: style, showAll: args.has("all")) }

    init(args: Args) {
        self.args = args
        var s = Style.detect(noColor: args.has("no-color"))
        s.fahrenheit = args.has("fahrenheit")
        style = s
    }

    /// A copy of thermo outside Thermo.app (say, copied into ~/.local/bin) does not update with the
    /// app; once the app is newer its readings can differ from the app's. A copy may be pinned
    /// for review, so point to the app CLI for future commands without proposing replacement.
    static func staleCopyWarning(executable: String? = Bundle.main.executableURL?.resolvingSymlinksInPath().path,
                                 version: String = thermoVersion,
                                 apps: [String] = ["/Applications/Thermo.app", NSHomeDirectory() + "/Applications/Thermo.app"]) -> String? {
        guard let executable, !executable.contains(".app/Contents/"), !executable.contains("/.build/") else { return nil }
        for app in apps {
            guard let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist"),
                  let appVersion = info["CFBundleShortVersionString"] as? String else { continue }
            guard version.compare(appVersion, options: .numeric) == .orderedAscending else { return nil }
            let cli = app + "/Contents/Helpers/thermo"
            let quotedCLI = "'" + cli.replacingOccurrences(of: "'", with: "'\\''") + "'"
            return "note: this thermo (\(version), \(executable)) is a copy older than \(app) \(appVersion) and does not update with it; "
                + "its readings may differ from the app's. App CLI for future commands: \(quotedCLI)."
        }
        return nil
    }

    func sampler() throws -> Sampler {
        try Sampler(scope: args.has("all") ? .all : .known, useCache: !args.has("no-cache"))
    }

    func run() throws {
        if let warning = Self.staleCopyWarning() { FileHandle.standardError.write(Data((warning + "\n").utf8)) }
        if args.has("version") {
            if args.has("json") {
                guard !args.has("csv") else { throw CLIError("Choose --json or --csv.") }
                print(Export.diagnosticJSON(Self.versionReport()))
            } else { print("thermo \(thermoVersion)") }
            return
        }
        let cmd = args.positionals.first ?? ""
        let rest = Array(args.positionals.dropFirst())
        if args.has("help") || cmd == "help" { print(CommandHelp.text(for: args.positionals)); return }
        try CommandContract.validate(args)
        if ["temps","temp","t","fans","f","power","p","battery","b","watch","w","list","ls","bench","capabilities"].contains(cmd), !rest.isEmpty {
            throw CLIError("This command does not take positional arguments.")
        }

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
        case "awake": try AwakeCommand(app: self).run(rest)
        case "awdl": try AWDLCommand(app:self).run(rest)
        case "charge": try ChargeCommand(app: self).run(rest)
        case "history": try HistoryCommand(app: self).run(rest)
        case "privacy": try PrivacyCommand(app: self).run(rest)
        case "claude-reset": try ClaudeResetCommand(app: self).run(rest)
        case "app-control", "screen", "permissions", "integration", "keep-awake": try AppControlCommand(app: self).run(command: cmd, rest: rest)
        case "capabilities": print(Export.json(CommandHelp.inventory))
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
                        currents: s.currents.filter(\.known), battery: s.battery, fansAvailable: s.fansAvailable)
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
        if sub == "status" {
            guard rest.count <= 1 else { throw CLIError("fan status takes no arguments") }
            let sm = try sampler(), client = HelperClient()
            let s = sm.sample()
            var policies: [Int: FanPolicy] = [:]
            var controlState: FanControlState?
            var helperNote: String?
            do {
                controlState = try client.blocking(timeout: 7) { try await $0.fanControlState() }
                policies = controlState?.policies ?? [:]
            } catch { helperNote = String(describing: error) }
            if args.has("json") {
                struct Status: Encodable { let fans: [FanReading]; let fansAvailable: Bool; let policies: [String: FanPolicy]; let helper: String?; let policiesAvailable: Bool; let controlState: FanControlState? }
                print(Export.json(Status(fans: s.fans, fansAvailable: s.hasFanReadings,
                                         policies: Dictionary(uniqueKeysWithValues: policies.map { (String($0.key), $0.value) }),
                                         helper: helperNote, policiesAvailable: helperNote == nil, controlState: controlState)))
                return
            }
            if args.has("csv") { print(Export.fanStatusCSV(s.fans, policies: policies, helperNote: helperNote, controlState: controlState, fansAvailable: s.hasFanReadings)); return }
            out(renderer.fans(s))
            print("")
            print(style.bold("Requested policies (not hardware confirmation)"))
            out(renderer.requestedFanPolicies(s.fans, policies: policies, controlState: controlState, available: helperNote == nil))
            if let helperNote { print(style.dim("  " + helperNote)) }
            if let failure = controlState?.failure { print("  control failure: " + failure) }

            return
        }
        let policy: FanPolicy, label: String, target: String
        switch sub {
        case "set":
            guard rest.count == 3 else { throw CLIError("usage: thermo fan set ID_or_all RPM_or_max") }
            let rpm = try Self.fanRPM(rest[2])
            policy = .fixed(rpm:rpm); label = "fixed " + Self.fanRPMText(rpm); target = rest[1]
        case "curve":
            guard rest.count == 3 else { throw CLIError("usage: thermo fan curve ID_or_all CURVE") }
            let sensor = try CurveSensor(rawValue:args.options["sensor"] ?? "cpu").orThrow(CLIError("--sensor must be cpu, gpu or max"))
            let curve = try FanCurve(parsing:rest[2],sensor:sensor)
            policy = .curve(curve); label = curve.description; target = rest[1]
        case "auto":
            guard rest.count <= 2 else { throw CLIError("fan auto takes one optional fan ID") }
            policy = .auto; label = "auto"; target = rest.count == 2 ? rest[1] : "all"
        default: throw CLIError("unknown fan operation")
        }
        guard target == "all" || Int(target).map({ $0 >= 0 }) == true else { throw CLIError("invalid fan ID") }
        if args.has("dry-run") {
            receipt("fan." + sub,dryRun:true,outcome:"planned",message:"Requested fan \(target) policy \(label); execution validates hardware and helper. No writes performed.")
            return
        }
        let sm = try sampler(), client = HelperClient()
        guard sm.discovery.fansKnown else { throw CLIError("fan discovery unavailable; retry after SMC communication recovers") }
        try applyFan(policy,label:label,ids:fanTargets(target,fans:sm.fans),client:client)
    }

    func applyFan(_ policy: FanPolicy, label: String, ids: [Int], client: HelperClient) throws {
        struct Result: Encodable {
            let policy: String; let acceptedFanIDs: [Int]; let failed: [String:String]
            let observed: FanControlState?; let observationIssue: String?; let outcome: String
        }
        var accepted: [Int] = [], failures: [String:String] = [:]
        for id in ids {
            do { try client.blocking(timeout: 15) { try await $0.setPolicy(policy, fan: id) }; accepted.append(id) }
            catch { failures[String(id)] = String(describing:error) }
        }
        var observed: FanControlState?, issue: String?
        do { observed = try client.blocking(timeout:7) { try await $0.fanControlState() } }
        catch { issue = String(describing:error) }
        let complete = failures.isEmpty && issue == nil && observed?.failure == nil
        let result = Result(policy:label, acceptedFanIDs:accepted, failed:failures, observed:observed,
                            observationIssue:issue, outcome:complete ? "accepted" : "partial")
        if args.has("json") { print(Export.json(result)) }
        else { print("fan policy " + label + " · accepted: " + accepted.map(String.init).joined(separator:", ")); for (id, failure) in failures.sorted(by: { $0.key < $1.key }) { print(id + ": " + failure) }; if let issue { print(issue) } }
        if !complete { throw CLIError("Fan control was partial or could not be observed; inspect fan status before another request.", exitCode:3) }
    }

    func warnClamp(_ rpm: Double, sm: Sampler) {
        guard rpm.isFinite, rpm > 0 else { return }
        for f in sm.sample().fans {
            guard let range = f.validRange, rpm < range.min || rpm > range.max else { continue }
            FileHandle.standardError.write("thermo: note: \(f.name) is limited to \(Renderer.fanNumber(range.min))–\(Renderer.fanNumber(range.max)) rpm; value clamped\n".data(using: .utf8)!)
        }
    }

    // MARK: helper

    static func helperStatusFields(legacyInstalled: Bool, version: String?) -> [String: String] {
        ["installed": legacyInstalled || version != nil ? "true" : "false",
         "running": version != nil ? "true" : "false", "version": version ?? "",
         "installationSource": legacyInstalled ? "legacy" : version != nil ? "connected" : "unknown"]
    }

    func helperCommand(_ rest: [String]) throws {
        guard rest.count <= 1 else { throw CLIError("helper takes status, install or uninstall") }
        if args.has("dry-run"), let verb = rest.first, ["install","uninstall"].contains(verb) {
            receipt("helper." + verb, dryRun: true, outcome: "planned", message: "Legacy helper \(verb) with administrator approval. For App background registration use app-control helper. No changes made."); return
        }
        switch rest.first ?? "status" {
        case "install":
            guard let bin = HelperInstaller.locateHelperBinary() else {
                throw CLIError("thermo-helper binary not found next to thermo or in /Applications/Thermo.app")
            }
            if !args.has("json") { print("Installing helper from \(bin.path) (administrator password required)…") }
            try HelperInstaller.install(from: bin)
            let v = try? HelperClient().blocking(timeout: 5) { try await $0.version() }
            let confirmed = v == HelperConstants.version
            receipt("helper.install", outcome: confirmed ? "succeeded" : "unconfirmed", message: confirmed ? "helper installed and running" : "helper installation version is unconfirmed")
            if !confirmed { throw CLIError("Expected helper \(HelperConstants.version), observed \(v ?? "no response").", exitCode: 3) }
        case "uninstall":
            guard HelperInstaller.isInstalled else {
                throw CLIError("legacy helper installation not detected; remove an app-registered helper in Thermo settings")
            }
            try HelperInstaller.uninstall()
            receipt("helper.uninstall", message: "helper removed; automatic fan control confirmed before removal")
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
    fail(e.description, code: e.exitCode)
} catch {
    fflush(stdout)
    fail("\(error)")
}
