import AgentCore
import Foundation
import ThermoKit

struct AppControlCommand {
    let app: App
    struct Operation {
        let action: String
        let arguments: [String: String]
        let mutates: Bool
    }
    static func operation(command: String, rest: [String], args: Args) throws -> Operation {
        let sub = rest.first ?? "status"
        var action: String, values: [String:String] = [:], mutates = false
        switch command {
        case "keep-awake":
            guard rest.count <= 1, ["status", "start", "stop"].contains(sub) else { throw CLIError("Run thermo keep-awake --help.") }
            action = "keep-awake." + sub; mutates = sub != "status"
            if sub == "start" {
                guard let mode = IdleAwakeMode(rawValue: args.options["mode"] ?? "both") else { throw CLIError("--mode must be display, tasks or both") }
                values["mode"] = mode.rawValue
                if let duration = args.options["duration"] {
                    guard duration == "manual", args.options["seconds"] == nil else { throw CLIError("Use --duration manual or --seconds, not both") }
                    values["duration"] = "manual"
                } else {
                    guard let seconds = Int(args.options["seconds"] ?? "3600"), (1...604800).contains(seconds) else { throw CLIError("--seconds must be 1…604800") }
                    values["seconds"] = String(seconds)
                }
            }
        case "screen":
            guard rest.count <= 1, ["status","start","stop","duration","shortcut","clear-shortcut"].contains(sub) else { throw CLIError("Run thermo screen --help.") }
            action = "screen." + sub; mutates = sub != "status"
            if sub == "duration", args.options["duration"] == nil { throw CLIError("screen duration requires --duration; use screen status to read the saved preference") }
            if sub == "start" || sub == "duration", let duration = args.options["duration"] {
                guard ["oneMinute","twoMinutes","fiveMinutes","manual"].contains(duration) else { throw CLIError("--duration must be oneMinute, twoMinutes, fiveMinutes or manual") }
                values["duration"] = duration
            }
            if sub == "shortcut" {
                for name in ["key-code","modifiers","key-label"] {
                    guard let value = args.options[name] else { throw CLIError("screen shortcut requires --key-code, --modifiers and --key-label") }
                    values[name] = value
                }
            }
        case "permissions":
            guard rest.count <= 1, ["status","notifications","accessibility","login"].contains(sub) else { throw CLIError("Run thermo permissions --help.") }
            action = "permissions." + sub; mutates = sub != "status"
        case "integration":
            guard rest.count <= 1, ["status","link","claude","codex"].contains(sub) else { throw CLIError("Run thermo integration --help.") }
            action = "integration." + sub; mutates = sub != "status"
        default:
            if sub == "status" { guard rest.count <= 1 else { throw CLIError("app-control status takes no arguments") }; action = "status" }
            else {
                guard rest.count <= 2, ["login","updates","helper","awdl"].contains(sub) else { throw CLIError("Run thermo app-control --help.") }
                let verb = rest.dropFirst().first ?? "status"
                let allowed = sub == "awdl" ? ["status","on","off"] : sub == "login" ? ["status","on","off"] : sub == "updates" ? ["status","on","off","check"] : ["status","install","uninstall"]
                guard allowed.contains(verb) else { throw CLIError("Unknown \(sub) operation.") }
                action = sub + "." + verb; mutates = verb != "status"
                if sub == "awdl", verb == "on" {
                    guard let seconds = Int(args.options["seconds"] ?? "300"), (60...3600).contains(seconds) else { throw CLIError("--seconds must be 60…3600") }
                    values["seconds"] = String(seconds)
                }
            }
        }
        let scoped = Set(["duration","key-code","modifiers","key-label","seconds","mode"])
        let unexpected = Set(args.options.keys).intersection(scoped).subtracting(values.keys)
        guard unexpected.isEmpty else { throw CLIError("Options do not apply to this operation: " + unexpected.sorted().joined(separator:", ")) }
        return Operation(action: action, arguments: values, mutates: mutates)
    }
    func run(command: String, rest: [String]) throws {
        let operation = try Self.operation(command: command, rest: rest, args: app.args)
        if operation.mutates && !app.args.has("dry-run") {
            let prompt = command == "keep-awake" ? "Apply idle-awake \(rest.first ?? "status") through Thermo.app? The session ends when its duration expires or Thermo quits." : "Apply \(operation.action) through Thermo.app? Permission, helper and update actions may display macOS or App dialogs."
            try app.approveAction(prompt)
        }
        let request = AppControlRequest(action: operation.action, arguments: operation.arguments, dryRun: app.args.has("dry-run"))
        let serverTrust: LocalControlPeerTrust?
        if let team = CodeSignature.teamIdentifier() {
            serverTrust = try LocalControlPeerTrust(team:team,developmentExecutable:URL(fileURLWithPath:"/unused-in-production"),role:.app)
        } else { serverTrust = nil } // Unbundled development/test peers remain same-UID only on this side.
        let reply = try AppControlTransport.request(request, timeout: operation.action.hasPrefix("integration.") || operation.action.hasPrefix("helper.") ? 290 : 20,
            authorizeServer:{ serverTrust?.accepts(auditToken:$0) ?? true })
        if app.args.has("json") { print(Export.json(reply)) }
        else { print(reply.values.keys.sorted().map { $0 + ": " + reply.values[$0]! }.joined(separator: "\n")); if let issue = reply.issue { print(issue) } }
        guard reply.succeeded else { throw CLIError(reply.issue ?? "App operation was not confirmed.", exitCode: 3) }
    }
}
