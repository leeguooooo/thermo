import Foundation

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Minimal argument parser: positionals plus `--flag`, `--opt value`, `--opt=value`, `-x value`.
struct Args {
    var positionals: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    static let valueOptions: Set<String> = ["interval", "count", "sensor", "format", "older-than", "root", "budget", "timeout",
                                            "area", "agent", "action",
        "to", // space archive: SSH alias:/absolute/archive.tar
        "since",  // pulse history
        "limit",  // history
        "watch", "app", "title", "ids", "group", "name", "window", "color"]  // pulse chrome
    static let aliases: [String: String] = [
        "i": "interval", "n": "count", "s": "sensor", "a": "all", "j": "json",
        "h": "help", "v": "version", "f": "format", "y": "yes",
    ]
    static let knownFlags: Set<String> = ["json", "csv", "all", "no-color", "no-cache", "help", "version", "fahrenheit", "yes", "trash", "permanent", "dry-run", "with-data",
        "exact", // clean: full per-item size walks
        "stream", // clean: newline-delimited incremental scan results
        "rescan",  // rescan: clean run ignores the saved scan
        "remove-local", "inactive-development",
        "measure", "all-windows", "by-site",
        "no-heat-guard"]  // awake on: only low battery turns it off  // pulse chrome: measure memory per page once

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
