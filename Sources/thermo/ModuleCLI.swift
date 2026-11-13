import AgentCore
import Foundation
import ModuleKit
import ThermoKit

/// Module discovery and routing share the same declarations as the App. Arguments are never
/// reparsed as shell/CLI text after validation: values such as "--yes" remain item IDs.
enum ModuleCLI {
    struct Invocation: Codable, Sendable {
        let tool: String
        let arguments: [String: ModuleArgument]
    }
    static func defaults() throws -> UserDefaults {
        guard let value = UserDefaults(suiteName: ModulePreferences.appDomain) else { throw CLIError("Cannot read module settings.") }
        value.synchronize()
        return value
    }
    static func manifests() -> [ModuleManifest] {
        var app: URL?
        var ancestor = Bundle.main.executableURL?.resolvingSymlinksInPath()
        for _ in 0..<8 {
            if ancestor?.pathExtension == "app" { app = ancestor; break }
            ancestor = ancestor?.deletingLastPathComponent()
        }
        if app == nil { app = ["/Applications/Thermo.app",NSHomeDirectory()+"/Applications/Thermo.app"].map { URL(fileURLWithPath:$0) }.first { FileManager.default.fileExists(atPath:$0.path) } }
        return BuiltinModuleManifests.all + (app.map { ModuleBundles.installed(in:$0).modules.map(\.manifest) } ?? [])
    }
    static func catalog(includeDisabled: Bool = false, manifests supplied: [ModuleManifest]? = nil, defaults suppliedDefaults: UserDefaults? = nil) throws -> ModuleCommandCatalog {
        let settings = try suppliedDefaults ?? defaults()
        return try ModuleCommandCatalog(supplied ?? manifests(),enabled:{ includeDisabled || ModulePreferences.isEnabled($0,in:settings) })
    }
    static func requireEnabled(_ manifest: ModuleManifest, defaults supplied: UserDefaults? = nil) throws {
        let settings = try supplied ?? defaults()
        guard ModulePreferences.isEnabled(manifest,in:settings) else { throw CLIError("\(manifest.name) is switched off. Enable it in Thermo Settings before using its commands.") }
    }
    static func normalized(_ path: [String]) -> [String] {
        var result = path
        if let root = result.first { result[0] = HostCommandSpecification.aliases[root] ?? root }
        if result.count > 1 && result[0] == "clean" && result[1] == "space" { result[1] = "overview" }
        return result
    }
    static func handles(_ argv: [String]) -> Bool {
        let root = normalized((try? Args(argv))?.positionals ?? argv).first
        if root == "clean" { return true }
        guard let root, !CommandHelp.coreCapabilities.contains(where: { $0.command.split(separator:" ").first.map(String.init) == root }) else { return false }
        return (try? catalog(includeDisabled:true))?.entries.contains { $0.cliPath.first == root } ?? false
    }
    static func run(_ argv: [String]) throws {
        let parsed = try? Args(argv)
        if parsed?.has("version") == true { try App(args:parsed!).run(); return }
        let catalog = try ModuleCLI.catalog(includeDisabled:true)
        let words = normalized(parsed?.positionals ?? argv)
        guard let entry = catalog.command(matching:words),let manifest = manifests().first(where:{$0.id == entry.moduleID}) else { throw CLIError("Unknown module command.") }
        try requireEnabled(manifest)
        if parsed?.has("help") == true { print(CommandHelp.text(for:words)); return }
        let indices = parsed.map { Set($0.positionalIndices.prefix(entry.cliPath.count)) } ?? Set(0..<entry.cliPath.count)
        let remaining = argv.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
        let values = try entry.parseCLI(remaining, controls:[.init(name:"no-color",kind:.boolean,summary:"Disable ANSI colors.")],aliases:Args.aliases)
        var business = values; business.removeValue(forKey:"no-color")
        try execute(entry,arguments:business,literalRoots:false,noColor:values["no-color"] == .boolean(true))
    }
    static func execute(_ entry: ModuleCommandCatalog.Entry, arguments: [String:ModuleArgument], literalRoots: Bool, noColor: Bool = false, catalog supplied: ModuleCommandCatalog? = nil) throws {
        guard let current = try (supplied ?? catalog()).tool(named:entry.toolName) else { throw CLIError("The module is switched off or this command is no longer available.") }
        try current.validate(arguments)
        guard current.moduleID == BuiltinModuleManifests.disk.id else { try runExternal(current,arguments:arguments); return }
        var args = try Args([])
        args.positionals = current.cliPath
        if noColor { args.flags.insert("no-color") }
        for (name,value) in arguments {
            switch value {
            case .boolean(true): args.flags.insert(name)
            case .boolean(false), .array: break
            case .string(let text): args.options[name] = text
            case .integer(let n): args.options[name] = String(n)
            }
        }
        guard !(args.has("json") && args.has("csv")) else { throw CLIError("Choose --json or --csv.") }
        func strings(_ name: String) -> [String] {
            guard let value = arguments[name] else { return [] }
            if case .array(let values) = value { return values.compactMap { if case .string(let text) = $0 { return text };return nil } }
            if case .string(let text) = value { return [text] }
            return []
        }
        let roots = arguments["root"].flatMap { value -> [String]? in
            guard case .array = value else { return nil }
            let values = strings("root")
            return literalRoots ? values : values.flatMap { $0.split(separator:",").map(String.init) }
        }
        let clean = CleanCommand(app:App(args:args),projectRoots:roots)
        try clean.validateInvocation(current.command.id)
        // Pick the implementation from the declared command, never from an argument's contents.
        switch current.command.id {
        case "scan": try clean.report(filter:strings("categories"))
        case "overview": try clean.overview()
        case "run": try clean.clean(strings("targets"))
        case "plan": try clean.savePlan(strings("targets"))
        case "apply": try clean.applyPlan(strings("plan"))
        case "log": clean.showLog()
        case "whitelist": try clean.whitelist(strings("action") + strings("paths"))
        case "restore": try clean.restoreBatch(strings("batch"))
        case "empty-trash": try clean.emptyTrash(strings("batch"))
        case "repair-worktrees": try clean.repairWorktrees()
        default: throw CLIError("No implementation for module command \(current.command.id).")
        }
    }
    static func runExternal(_ entry: ModuleCommandCatalog.Entry,arguments:[String:ModuleArgument]) throws {
        let encoded = try JSONEncoder().encode(arguments)
        let request = AppControlRequest(action:"modules.run",arguments:["module":entry.moduleID,"command":entry.command.id,"arguments":String(decoding:encoded,as:UTF8.self)],dryRun:arguments["dry-run"] == .boolean(true))
        let trust = try CodeSignature.teamIdentifier().map { try LocalControlPeerTrust(team:$0,developmentExecutable:URL(fileURLWithPath:"/unused-in-production"),role:.app) }
        let response = try AppControlTransport.request(request,timeout:290,authorizeServer:{ trust?.accepts(auditToken:$0) ?? true })
        guard response.succeeded,let result = response.values["moduleResult"] else { throw CLIError(response.issue ?? "Module result is unconfirmed. Do not retry an uncertain change.",exitCode:3) }
        print(result)
    }
    static func runChildRequest() throws {
        var data = Data()
        while let part = try FileHandle.standardInput.read(upToCount:4096),!part.isEmpty {
            data.append(part)
            guard data.count <= 65536 else { throw CLIError("Module request exceeds 64 KiB.") }
        }
        let request = try JSONDecoder().decode(Invocation.self,from:data)
        guard let entry = try catalog().tool(named:request.tool) else { throw CLIError("The module is switched off or this command is unavailable.") }
        try execute(entry,arguments:request.arguments,literalRoots:true,noColor:true)
    }
}
