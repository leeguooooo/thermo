import Foundation
import ThermoKit

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
    static var inventory: Inventory { Inventory(commands:capabilities) }
    static let specification = """
    temps|temps [--json|--csv]|cli
    fans|fans [--json|--csv]|cli
    power|power [--json|--csv]|cli
    battery|battery [--json|--csv]|cli
    watch|watch [--count N] [--interval SEC] [--json|--csv]|cli
    list|list [--json|--csv]|cli
    get|get KEY… [--json|--csv]|cli
    bench|bench [--json|--csv]|cli
    fan status|fan status [--json|--csv]|helper
    fan set|fan set ID_or_all RPM_or_max [--dry-run] [--json]|helper
    fan curve|fan curve ID_or_all CURVE [--sensor cpu_or_gpu_or_max] [--dry-run] [--json]|helper
    fan auto|fan auto [ID_or_all] [--dry-run] [--json]|helper
    helper status|helper status [--json|--csv]|helper
    helper install|helper install [--dry-run] [--json]|helper
    helper uninstall|helper uninstall [--dry-run] [--json]|helper
    activity|activity [--json]|cli
    memory|memory [--json]|cli
    pulse|pulse [--json|--csv]|cli
    pulse inspect|pulse inspect NAME_or_PID [--json]|cli
    pulse explain|pulse explain PID [--json]|cli
    pulse history|pulse history [--since 6h] [--json]|app-recorded-history
    pulse quit|pulse quit NAME_or_PID [--dry-run] [--yes] [--json]|cli
    pulse restart|pulse restart NAME_or_PID [--dry-run] [--yes] [--json]|cli
    pulse chrome|pulse chrome [--app BROWSER] [--watch SEC] [--measure] [--json|--csv]|browser
    pulse chrome close|pulse chrome close [URL] [--ids IDS] [--app BROWSER] [--title TITLE] [--dry-run] [--yes] [--json]|browser
    agents|agents [--all] [--json|--csv]|cli
    agents context|agents context [--encoding ENCODING] [--agent AGENT] [--root PROJECT] [--json]|cli
    agents usage|agents usage [--encoding ENCODING] [--all] [--since DATE] [--agent AGENT] [--limit N] [--json]|cli
    agents compare|agents compare FILE [--json]|cli
    agents inspect-all|agents inspect-all [--agent AGENT] [--encoding ENCODING] [--timeout SEC] [--budget SEC] [--dry-run] [--json]|mcp
    agents inspect|agents inspect NAME [--encoding ENCODING] [--agent AGENT] [--timeout SEC] [--json]|mcp
    agents list|agents list [AREA] [--json|--csv]|cli
    agents show|agents show NAME [--area AREA] [--agent AGENT] [--json|--csv]|cli
    agents fix|agents fix [NAME] [--action N] [--area AREA] [--agent AGENT] [--all] [--dry-run] [--yes] [--json]|cli
    agents disable|agents disable NAME [--area AREA] [--agent AGENT] [--all] [--dry-run] [--yes] [--json]|cli
    agents uninstall|agents uninstall NAME [--area AREA] [--agent AGENT] [--all] [--dry-run] [--yes] [--json]|cli
    agents run|agents run NAME --action N [--area AREA] [--agent AGENT] [--all] [--dry-run] [--yes] [--json]|cli
    clean|clean [CATEGORY_or_ai] [--all] [--csv] [--root DIRS] [--older-than DAYS] [--budget SEC] [--exact] [--json|--stream]|cli
    clean overview|clean overview [--budget SEC] [--json|--stream]|cli
    clean run|clean run safe_or_ID… [--budget SEC] [--exact] [--rescan] [--root DIRS] [--older-than DAYS] [--dry-run] [--yes] [--trash|--permanent] [--json]|cli
    clean plan|clean plan safe_or_ID… [--rescan] [--root DIRS] [--budget SEC] [--trash|--permanent] [--json]|cli
    clean apply|clean apply UUID [--dry-run] [--yes] [--json]|cli
    clean log|clean log [--all] [--json]|cli
    clean whitelist|clean whitelist [add_or_remove PATH…] [--dry-run] [--json]|cli
    clean restore|clean restore BATCH [--dry-run] [--yes] [--json]|cli
    clean empty-trash|clean empty-trash BATCH [--dry-run] [--yes] [--json]|cli
    clean repair-worktrees|clean repair-worktrees --root REPO [--dry-run|--yes] [--json]|cli
    apps|apps [--exact] [--json]|cli
    apps uninstall|apps uninstall NAME [--data-only] [--with-data] [--dry-run] [--yes] [--json]|cli
    apps leftovers|apps leftovers [remove ID…] [--dry-run] [--yes] [--json]|cli
    apps startup|apps startup [--authorize-background] [--json]|cli
    apps startup enable|apps startup enable LABEL_or_PATH [--dry-run] [--yes] [--json]|cli
    apps startup disable|apps startup disable LABEL_or_PATH [--dry-run] [--yes] [--json]|cli
    apps updates|apps updates [--refresh-catalog] [--json]|cli
    apps updates apply|apps updates apply TOKEN [--dry-run] [--yes] [--json]|cli
    apps updates sources|apps updates sources [--json]|cli
    apps updates check|apps updates check NAME [--dry-run] [--json]|cli
    apps updates install|apps updates install NAME [--dry-run] [--yes] [--json]|cli
    apps updates recovery|apps updates recovery [inspect_or_restore_or_trash-backup ID] [--dry-run] [--yes] [--json]|cli
    space|space [PATH] [--no-cache] [--all] [--json]|cli
    space large|space large [--older-than DAYS] [--json]|cli
    space dupes|space dupes [PATH…] [--json]|cli
    space dupes remove|space dupes remove PATH… --keep PATH [--dry-run] [--yes] [--json]|cli
    space trash|space trash PATH… [--dry-run] [--yes] [--json]|cli
    space archive|space archive PATH --to HOST:/PATH [--remove-local] [--inactive-development] [--dry-run] [--yes] [--json]|ssh
    tabs list|tabs list [--app BROWSER] [--json]|browser
    tabs groups|tabs groups [--app BROWSER] [--json]|browser
    tabs group|tabs group NAME --ids IDS [--by-site] [--dry-run] [--yes] [--json]|browser
    tabs archive|tabs archive [--ids IDS] [--group NAME] [--window ID|--all-windows] [--name NAME] [--dry-run] [--yes] [--json]|browser
    tabs saved|tabs saved [--json]|cli
    tabs show|tabs show UUID [--json]|cli
    tabs restore|tabs restore UUID [--window ID] [--dry-run] [--yes] [--json]|browser
    tabs organize|tabs organize [--app BROWSER] [--ids IDS] [--window ID|--all-windows] [--dry-run] [--yes] [--json]|browser
    tabs organized|tabs organized [--json]|cli
    tabs undo-organize|tabs undo-organize UUID [--dry-run] [--yes] [--json]|browser
    tabs auto|tabs auto [on|off] [--dry-run] [--yes] [--json]|app-worker
    tabs rule|tabs rule [add DOMAIN NAME|remove UUID] [--color COLOR] [--dry-run] [--yes] [--json]|cli
    awake|awake [status|on|off] [--no-heat-guard] [--dry-run] [--yes] [--json]|helper
    awdl|awdl [status|on|recover] [--probe] [--seconds SEC] [--dry-run] [--json]|helper-connection-lease
    settings|settings [KEY [VALUE]] [--dry-run] [--json|--csv]|cli
    history|history [list|show ID] [--limit N] [--json]|cli
    privacy profiles|privacy profiles [--json]|cli
    privacy location|privacy location [--dry-run] [--yes] [--json]|cli
    privacy webrtc|privacy webrtc [--dry-run] [--yes] [--json]|cli
    privacy cookies|privacy cookies [--dry-run] [--yes] [--json]|cli
    privacy restore-browser|privacy restore-browser [--dry-run] [--yes] [--json]|cli
    privacy environment|privacy environment [--dry-run] [--yes] [--json]|cli
    privacy dns|privacy dns [--dry-run] [--yes] [--json]|administrator
    privacy lookup|privacy lookup [--dry-run] [--json]|network
    privacy timezone|privacy timezone set --timezone ZONE_or_restore [--dry-run] [--yes] [--json]|administrator
    claude-reset list|claude-reset list [--json]|cli
    claude-reset run|claude-reset run TARGET… [--dry-run] [--yes] [--json]|cli
    claude-reset batches|claude-reset batches [--json]|cli
    claude-reset restore|claude-reset restore UUID [--dry-run] [--yes] [--json]|cli
    screen|screen [status|start|stop|duration|shortcut|clear-shortcut] [--duration oneMinute_or_twoMinutes_or_fiveMinutes_or_manual] [--key-code N --modifiers N --key-label LABEL] [--dry-run] [--yes] [--json]|app
    app-control|app-control status [--json]|app
    app-control login|app-control login [status|on|off] [--dry-run] [--yes] [--json]|app
    app-control updates|app-control updates [status|check|on|off] [--dry-run] [--yes] [--json]|app
    app-control awdl|app-control awdl [status|on|off] [--seconds SEC] [--dry-run] [--yes] [--json]|app-helper-lease
    app-control helper|app-control helper [status|install|uninstall] [--dry-run] [--yes] [--json]|app
    permissions|permissions [status|notifications|accessibility|login] [--dry-run] [--yes] [--json]|app
    integration|integration [status|link|claude|codex] [--dry-run] [--yes] [--json]|app
    capabilities|capabilities [--json]|cli
    """
    static let capabilities: [Capability] = specification.split(separator: "\n").map { line in
        let p = line.split(separator: "|", omittingEmptySubsequences: false)
        // Usage strings may contain the conventional '|' separator.
        return .init(command: String(p[0]), usage: p.dropFirst().dropLast().joined(separator: "|"), execution: String(p.last!))
    }
    static let aliases = ["temp":"temps","t":"temps","f":"fans","p":"power","b":"battery","w":"watch","ls":"list","agent":"agents","doctor":"agents","app":"apps","config":"settings","status":"pulse"]
    static func text(for words: [String]) -> String {
        var path = words.filter { $0 != "help" }
        if let first = path.first { path[0] = aliases[first] ?? first }
        if path.isEmpty {
            let descriptions = ["temps":"temperature sensors", "fans":"fan readings", "power":"power and electrical readings", "battery":"battery readings", "watch":"live sensor view", "list":"raw SMC keys", "get":"read selected SMC keys", "bench":"sampling benchmark", "fan":"fan policies and observed control state", "helper":"legacy helper installation and status", "activity":"CPU/GPU activity", "memory":"program memory and project contexts", "pulse":"slowdown diagnosis, process and browser actions", "agents":"Agent/MCP/Skill diagnosis, inspection and fixes", "clean":"disk scan, frozen plans, cleanup and recovery", "apps":"applications, updates, startup and residual data", "space":"folder sizes, large files, duplicates and verified archives", "tabs":"browser groups, saved batches and restoration", "awake":"lid-closed awake control", "awdl":"bounded network session held by this CLI", "settings":"shared App preferences", "history":"operation records and recovery references", "privacy":"browser, environment, DNS and timezone controls", "claude-reset":"explicit recoverable Claude local-data reset", "screen":"App-owned screen cleaning and shortcut", "app-control":"App status, login, updates, helper and AWDL", "permissions":"App permission state and system settings", "integration":"CLI links and Agent plugin setup", "capabilities":"versioned machine-readable command contracts"]
            let families = Set(capabilities.map { String($0.command.split(separator:" ").first!) }).sorted()
            let rows = families.map { "  " + $0.padding(toLength:15,withPad:" ",startingAt:0) + (descriptions[$0] ?? "Use --help for operations") }
            return (["thermo " + ThermoVersion.string + " — Mac diagnostics and controls", "", "USAGE: thermo [COMMAND] [OPTIONS]", "", "COMMANDS"] + rows + ["", "thermo COMMAND --help: scoped operations and options", "thermo capabilities --json: schema, version, formats and execution dependencies", "--dry-run previews supported operations; --yes confirms where requested.", "--json/--csv are accepted only where listed. --no-color disables ANSI output.", "No command defaults to clearing conversations or changing hardware."]).joined(separator:"\n")
        }
        var selected: [Capability] = []
        while !path.isEmpty {
            let prefix = path.joined(separator: " ")
            selected = capabilities.filter { $0.command == prefix || $0.command.hasPrefix(prefix + " ") }
            if !selected.isEmpty { break }; path.removeLast()
        }
        guard !selected.isEmpty else { return "Unknown command. Run thermo --help." }
        return selected.map { "thermo " + $0.usage + "\n  execution: " + $0.execution }.joined(separator: "\n\n")
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
            let families = ["clean", "apps", "app", "space", "tabs", "privacy", "claude-reset", "screen", "app-control", "permissions", "integration", "fan", "helper", "awake", "awdl", "settings", "config"]
            let agent = ["agents","agent","doctor"].contains(root) && ["fix","disable","uninstall","remove","rm","run","inspect-all"].contains(sub)
            let pulse = ["pulse","status"].contains(root) && (["quit","restart"].contains(sub) || Array(p.prefix(3)) == [root,"chrome","close"])
            guard families.contains(root) || agent || pulse else { throw CLIError("--dry-run is not supported for this command; no action was performed.") }
        }
        if args.has("csv") {
            guard ["temps","temp","t","fans","f","power","p","battery","b","watch","w","list","ls","get","memory","settings","config","helper","fan","pulse","status","bench","agents","agent","doctor"].contains(root),
                  !(["pulse","status"].contains(root) && ["quit","restart","explain","inspect"].contains(sub)),
                  !(root == "helper" && !["","status"].contains(sub)),
                  !(root == "fan" && !["","status"].contains(sub)) else { throw CLIError("This command supports --json, not --csv.") }
        }
    }
}
