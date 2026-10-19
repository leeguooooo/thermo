import Foundation
import AgentDoctor

struct CLIError: Error, CustomStringConvertible {
    let description: String
    let exitCode: Int32
    init(_ d: String, exitCode: Int32 = 2) { description = d; self.exitCode = exitCode }
}

/// Minimal argument parser: positionals plus `--flag`, `--opt value`, `--opt=value`, `-x value`.
struct Args {
    var positionals: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    static let valueOptions: Set<String> = ["interval", "count", "sensor", "format", "older-than", "root", "budget", "timeout",
                                            "area", "agent", "action", "encoding", "seconds", "duration", "mode", "timezone", "key-code", "modifiers", "key-label", "keep",
        "to", // space archive: SSH alias:/absolute/archive.tar
        "since",  // pulse history
        "limit",  // history
        "sort", // agents usage: observed text/structured JSON tokens or call interval order
        "protocol", // explicit MCP inspection lifecycle; never inferred from a version label
        "log-file", // agents usage: one explicitly selected session
        "watch", "app", "title", "ids", "group", "name", "window", "color"]  // pulse chrome
    static let aliases: [String: String] = [
        "i": "interval", "n": "count", "s": "sensor", "a": "all", "j": "json",
        "h": "help", "v": "version", "f": "format", "y": "yes",
    ]
    static let knownFlags: Set<String> = ["json", "csv", "all", "no-color", "no-cache", "help", "version", "fahrenheit", "yes", "trash", "permanent", "dry-run", "with-data",
        "refresh-catalog", "data-only", "authorize-background",
        "exact", // clean: full per-item size walks
        "stream", // clean: newline-delimited incremental scan results
        "rescan",  // rescan: clean run ignores the saved scan
        "remove-local", "inactive-development",
        "measure", "all-windows", "by-site", "tail",
        "no-heat-guard", "probe"]  // awake / read-only AWDL interface probe

    init(_ argv: [String]) throws {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            i += 1
            if a == "--" { positionals += argv[i...]; break }
            guard a.hasPrefix("-"), a.count > 1, Double(a) == nil else { positionals.append(a); continue }

            var name = a.hasPrefix("--") ? String(a.dropFirst(2)) : String(a.dropFirst())
            var inline: String?
            if let eq = name.firstIndex(of: "=") {
                inline = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
            }
            if !a.hasPrefix("--") { name = Args.aliases[name] ?? name }

            if Args.valueOptions.contains(name) {
                if let inline { options[name] = inline; continue }
                guard i < argv.count else { throw CLIError("option --\(name) needs a value") }
                options[name] = argv[i]
                i += 1
            } else if Args.knownFlags.contains(name) {
                guard inline == nil else { throw CLIError("--\(name) does not take a value") }
                flags.insert(name)
            } else {
                throw CLIError("unknown option '\(a)' (see thermo --help)")
            }
        }
        if flags.contains("data-only"), Array(positionals.prefix(2)) != ["apps", "uninstall"] {
            throw CLIError("--data-only is only supported by apps uninstall")
        }
        let isUsage = positionals.first.map { CommandHelp.aliases[$0] ?? $0 } == "agents" && positionals.dropFirst().first == "usage"
        if flags.contains("tail") {
            guard isUsage, options["log-file"] != nil, ["claude", "codex"].contains(options["agent"] ?? "") else {
                throw CLIError("--tail requires agents usage --log-file and --agent claude or codex")
            }
        }
        if let mode = options["protocol"] {
            guard positionals.first.map({ CommandHelp.aliases[$0] ?? $0 }) == "agents",
                  ["inspect", "inspect-all"].contains(positionals.dropFirst().first ?? "") else {
                throw CLIError("--protocol is only supported by agents inspect and inspect-all")
            }
            guard MCPInspectionProtocol(rawValue: mode) != nil else { throw CLIError("--protocol must be handshake or 2026-07-28") }
        }
        if options["log-file"] != nil, !isUsage {
            throw CLIError("--log-file is only supported by agents usage")
        }
        if let order = options["sort"] {
            guard isUsage else { throw CLIError("--sort is only supported by agents usage") }
            guard ToolUsageOrdering(rawValue: order) != nil else { throw CLIError("--sort must be text, structured or time") }
        }
        if flags.contains("authorize-background") {
            guard Array(positionals.prefix(2)) == ["apps", "startup"],
                  positionals.count == 2 || (positionals.count == 3 && positionals[2] == "list"),
                  !flags.contains("dry-run") else {
                throw CLIError("--authorize-background only supports apps startup list without --dry-run")
            }
        }
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }

    func double(_ name: String) throws -> Double? {
        guard let v = options[name] else { return nil }
        let trimmed = v.hasSuffix("s") ? String(v.dropLast()) : v
        guard let d = Double(trimmed), d.isFinite, d > 0 else { throw CLIError("--\(name) expects a positive number, got '\(v)'") }
        return d
    }

    func int(_ name: String) throws -> Int? {
        guard let v = options[name] else { return nil }
        guard let d = Int(v), d > 0 else { throw CLIError("--\(name) expects a positive integer, got '\(v)'") }
        return d
    }
}
