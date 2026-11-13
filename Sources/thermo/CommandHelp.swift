import Foundation
import ThermoKit
import ModuleKit

/// The public inventory is also used by scoped help and contract tests.
enum CommandHelp {
    struct Capability: Codable {
        let command: String
        let usage: String
        let execution: String
        let supportsDryRun: Bool
        let structuredFormats: [String]
        init(command: String, usage: String, execution: String) {
            self.command = command; self.usage = usage; self.execution = execution
            supportsDryRun = usage.contains("--dry-run")
            structuredFormats = (usage.contains("--json") ? ["json"] : []) + (usage.contains("--csv") ? ["csv"] : [])
        }
    }
    struct Inventory: Encodable {
        let schemaVersion = 1
        let version = ThermoVersion.string
        let appControlProtocol = 1
        let commands: [Capability]
    }
    static var inventory: Inventory { Inventory(commands:availableCapabilities) }
    static let specification = HostCommandSpecification.text
    static let coreCapabilities: [Capability] = specification.split(separator: "\n").map { line in
        let p = line.split(separator: "|", omittingEmptySubsequences: false)
        // Usage strings may contain the conventional '|' separator.
        return .init(command: String(p[0]), usage: p.dropFirst().dropLast().joined(separator: "|"), execution: String(p.last!))
    }
    static let capabilities: [Capability] = coreCapabilities + (try! ModuleCommandCatalog(BuiltinModuleManifests.all,enabled:{_ in true})).entries.map {
        Capability(command:$0.cliPath.joined(separator:" "),usage:$0.cliUsage,execution:"cli")
    }
    static var availableCapabilities: [Capability] {
        coreCapabilities + ((try? ModuleCLI.catalog().entries) ?? []).map {
            Capability(command:$0.cliPath.joined(separator:" "),usage:$0.cliUsage,execution:$0.moduleID == BuiltinModuleManifests.disk.id ? "cli" : "app-module")
        }
    }
    static let aliases = HostCommandSpecification.aliases
    static func text(for words: [String]) -> String {
        let capabilities = availableCapabilities
        var path = words.filter { $0 != "help" }
        if let first = path.first { path[0] = aliases[first] ?? first }
        if path.isEmpty {
            let descriptions = ["capture":"App-owned screenshots, pin actions and JavaScript", "temps":"temperature sensors", "fans":"fan readings", "power":"power and electrical readings", "battery":"battery readings", "charge":"foreground charging policy and read-only capability probe", "watch":"live sensor view", "list":"raw SMC keys", "get":"read selected SMC keys", "bench":"sampling benchmark", "fan":"fan policies and observed control state", "helper":"legacy helper installation and status", "activity":"CPU/GPU activity", "memory":"program memory and project contexts", "pulse":"slowdown diagnosis, process and browser actions", "agents":"Agent/MCP/Skill diagnosis, inspection and fixes", "clean":"disk scan, frozen plans, cleanup and recovery", "apps":"applications, updates, startup and residual data", "space":"folder sizes, large files, duplicates and verified archives", "tabs":"browser groups, saved batches and restoration", "awake":"lid-closed awake control", "keep-awake":"display/task sleep controls through Thermo.app", "awdl":"bounded network session held by this CLI", "settings":"shared App preferences", "history":"operation records and recovery references", "privacy":"browser, environment, DNS and timezone controls", "claude-reset":"explicit recoverable Claude local-data reset", "screen":"App-owned screen cleaning and shortcut", "app-control":"App status, login, updates, helper and AWDL", "permissions":"App permission state and system settings", "integration":"CLI links and Agent plugin setup", "capabilities":"versioned machine-readable command contracts"]
            let families = Set(capabilities.map { String($0.command.split(separator:" ").first!) }).sorted()
            let rows = families.map { "  " + $0.padding(toLength:15,withPad:" ",startingAt:0) + (descriptions[$0] ?? "Use --help for operations") }
            return (["thermo " + ThermoVersion.string + " — Mac diagnostics and controls", "", "USAGE: thermo [COMMAND] [OPTIONS]", "", "COMMANDS"] + rows + ["", "thermo COMMAND --help: scoped operations and options", "thermo --version [--json]: CLI version and containing App build metadata", "thermo capabilities --json: schema, version, formats and execution dependencies", "--dry-run previews supported operations; --yes confirms where requested.", "--json/--csv are accepted only where listed. --no-color disables ANSI output.", "No command defaults to clearing conversations or changing hardware."]).joined(separator:"\n")
        }
        var selected: [Capability] = []
        while !path.isEmpty {
            let prefix = path.joined(separator: " ")
            selected = capabilities.filter { $0.command == prefix || $0.command.hasPrefix(prefix + " ") }
            if !selected.isEmpty { break }; path.removeLast()
        }
        guard !selected.isEmpty else { return "Unknown command. Run thermo --help." }
        let charging = selected.contains { $0.command == "charge" || $0.command.hasPrefix("charge ") } ?
            "\n\nCharging controls require helper protocol 8. Full charge ends at a reported 100%, without external power, or when state is unavailable. A previous 80% policy resumes; a standalone full session ends. System charging protection still applies." : ""
        let usageOrdering = selected.contains { $0.command == "agents usage" } ?
            "\n\nagents usage defaults to --sort text (reference or estimated tokens). --sort structured ranks known MCP structured JSON counts first; unknown counts and other categories follow. Human output and JSON use the same order; text shares are shown only for text order. --sort time ranks sums of valid observed call intervals, counting overlaps per call; unknown timing follows known values. --sort errors ranks observed result errors plus host invocation failures, with unmeasured counts last; missing results and unknown statuses are excluded. This is not a failure rate or quality score. --sort instructions ranks source-linked Skill instruction text, with unknown or incomplete loads last; it does not estimate unobserved loading. None of these orders measures request usage or task duration." : ""
        return selected.map { "thermo " + $0.usage + "\n  execution: " + $0.execution }.joined(separator: "\n\n") + charging + usageOrdering
            + "\n\n--dry-run never applies changes. Unsupported flags are rejected.\nApp commands require a running compatible Thermo.app. No request is automatically retried.\nExit 0: completed; 2: invalid/refused; 3: partial or unconfirmed result; 1: execution error."
    }
}

/// Never silently accept a preview/output flag on a path that does not implement it.
enum CommandContract {
    static func validate(_ args: Args) throws {
        if args.has("json") && args.has("csv") { throw CLIError("Choose --json or --csv.") }
        let p = args.positionals
        guard let root = p.first else {
            guard args.options.keys.allSatisfy({ $0 == "sensor" }), args.flags.isSubset(of:["json","csv","all","no-color","no-cache","fahrenheit","help","version"]) else { throw CLIError("Unsupported option for the default overview.") }
            return
        }
        let sub = p.dropFirst().first ?? ""
        var canonical = p
        let aliases = CommandHelp.aliases
        canonical[0] = aliases[root] ?? root
        if canonical.count > 1 {
            let key = canonical[1]
            if canonical[0] == "apps" { canonical[1] = ["remove":"uninstall","rm":"uninstall","orphans":"leftovers","list":"","ls":""][key] ?? key }
            if canonical[0] == "agents" { canonical[1] = ["remove":"uninstall","rm":"uninstall","ls":"list"][key] ?? key }
            if canonical[0] == "space" { canonical[1] = ["rm":"trash","duplicates":"dupes","big":"large","browse":""][key] ?? key }
        }
        let matching = CommandHelp.capabilities.filter { capability in
            let words = capability.command.split(separator: " ").map(String.init)
            return Array(canonical.prefix(words.count)) == words
        }.max { $0.command.count < $1.command.count }
        if let matching {
            let expression = try NSRegularExpression(pattern: "--[a-z][a-z-]*")
            let text = matching.usage as NSString
            var allowed = Set(expression.matches(in: matching.usage, range: NSRange(location:0,length:text.length)).map { text.substring(with:$0.range).dropFirst(2).description })
            allowed.formUnion(["no-color","help","version"])
            if canonical[0] == "fan" || canonical[0] == "helper" || canonical[0] == "settings" { allowed.insert("yes") }
            if ["temps","fans","power","battery","watch","list","get"].contains(canonical[0]) { allowed.formUnion(["all","no-cache","fahrenheit","sensor"]) }
            let supplied = args.flags.union(args.options.keys)
            let unknown = supplied.subtracting(allowed)
            guard unknown.isEmpty else { throw CLIError("Unsupported options for \(matching.command): " + unknown.sorted().map { "--" + $0 }.joined(separator:", ")) }
        }
        if args.has("dry-run") {
            let families = ["capture", "clean", "apps", "app", "space", "tabs", "privacy", "claude-reset", "screen", "app-control", "permissions", "integration", "fan", "helper", "awake", "keep-awake", "awdl", "charge", "settings", "config"]
            let agent = ["agents","agent","doctor"].contains(root) && ["fix","disable","uninstall","remove","rm","run","inspect-all"].contains(sub)
            let pulse = ["pulse","status"].contains(root) && (["quit","restart","end"].contains(sub) || Array(p.prefix(3)) == [root,"chrome","close"])
            guard families.contains(root) || agent || pulse else { throw CLIError("--dry-run is not supported for this command; no action was performed.") }
        }
        if args.has("csv") {
            guard ["temps","temp","t","fans","f","power","p","battery","b","watch","w","list","ls","get","memory","settings","config","helper","fan","pulse","status","bench","agents","agent","doctor","clean"].contains(root),
                  !(["pulse","status"].contains(root) && ["quit","restart","explain","inspect","why","end"].contains(sub)),
                  !(root == "helper" && !["","status"].contains(sub)),
                  !(root == "fan" && !["","status"].contains(sub)) else { throw CLIError("This command supports --json, not --csv.") }
        }
    }
}
