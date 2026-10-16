import Foundation
import AgentCore

/// Scope is a conservative tool-managed boundary, separate from paths Thermo itself may delete.
enum ManagedToolScope {
    typealias Runner = ([String]) -> (Int32, String)
    static let ids: Set<String> = ["homebrew-old-versions", "go-mod-cache", "pnpm-store-prune"]
    static let unavailable = "Tool cleanup scope could not be verified; scan again before cleaning."

    static func systemSpelling(_ path: String) -> String { FS.systemSpelling(path) }

    static func root(_ raw: String, home: String) -> String? {
        guard raw.hasPrefix("/"), !raw.unicodeScalars.contains(where: { $0.value < 32 }),
              !raw.split(separator: "/").contains("..") else { return nil }
        let path = systemSpelling(URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL.path)
        let homes = [home, ProcessInfo.processInfo.environment["HOME"]].compactMap { $0 }.map { systemSpelling(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) }
        let forbidden = ["/", "/Users", "/Volumes", "/System", "/Library", "/usr", "/opt", "/private", "/var", "/tmp"] + homes + homes.flatMap { h in ["Documents", "Downloads", "Desktop", "Library", "Pictures", "Movies", "Music"].map { h + "/" + $0 } }
        guard !Set(forbidden.map { systemSpelling(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) }).contains(path) else { return nil }
        for h in homes {
            for suffix in [".ssh", ".gnupg", ".aws", ".kube", "Library/Keychains", "Library/Mail", "Library/Messages", ".codex", ".claude"] {
                let sealed = h + "/" + suffix
                if path == sealed || path.hasPrefix(sealed + "/") { return nil }
            }
        }
        return path
    }

    static func value(_ output: String) -> String? {
        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines.count == 1 ? lines[0] : nil
    }

    static func path(_ output: String, home: String) -> String? {
        guard let reported = value(output) else { return nil }
        return root(reported, home: home)
    }

    /// A reported path may contain significant trailing spaces. Never trim it as prose.
    static func read(_ argv: [String]) -> (Int32, String) {
        let token = ScanCancellation.current
        let result = CommandRunner.run("/usr/bin/env", arguments: argv, timeout: 15, cancelled: { token?.isCancelled == true })
        guard !result.cancelled, !result.timedOut, !result.truncated else { return (-1, "scope query incomplete") }
        return (result.status, result.output)
    }

    static func parts(_ command: [String]) -> (environment: [String], executable: String, args: [String])? {
        let environment = Array(command.prefix { $0.contains("=") && !$0.hasPrefix("/") })
        guard environment.count < command.count else { return nil }
        return (environment, command[environment.count], Array(command.dropFirst(environment.count + 1)))
    }

    static func scope(_ command: [String], id: String, home: String, run: Runner) -> [String]? {
        guard let p = parts(command) else { return nil }
        func environment(_ key: String) -> String? {
            let matches = p.environment.filter { $0.hasPrefix(key + "=") }
            return matches.count == 1 ? String(matches[0].dropFirst(key.count + 1)) : nil
        }
        func query(_ args: [String]) -> String? {
            let result = run(p.environment + [p.executable] + args)
            return result.0 == 0 ? path(result.1, home: home) : nil
        }
        let name = (p.executable as NSString).lastPathComponent
        switch id {
        case "go-mod-cache":
            guard name == "go", p.args == ["clean", "-modcache"], environment("GOTOOLCHAIN") == "local", let bound = environment("GOMODCACHE"),
                  let dir = root(bound, home: home), query(["env", "GOMODCACHE"]) == dir else { return nil }
            return [dir]
        case "homebrew-old-versions":
            guard name == "brew", p.args.count == 2, p.args[0] == "cleanup", p.args[1].hasPrefix("--prune="),
                  environment("HOMEBREW_NO_AUTO_UPDATE") == "1", environment("HOMEBREW_NO_AUTOREMOVE") == "1",
                  let cacheRaw = environment("HOMEBREW_CACHE"), let logsRaw = environment("HOMEBREW_LOGS"),
                  let cache = root(cacheRaw, home: home), let logs = root(logsRaw, home: home),
                  let prefix = query(["--prefix"]), let cellar = query(["--cellar"]), let repository = query(["--repository"]),
                  query(["--cache"]) == cache else { return nil }
            return Array(Set([prefix, cellar, repository, cache, logs])).sorted()
        case "pnpm-store-prune":
            guard name == "pnpm", p.args.count == 6, Array(p.args.suffix(2)) == ["store", "prune"],
                  let homeRaw = environment("PNPM_HOME"), let pnpmHome = root(homeRaw, home: home) else { return nil }
            let flags = Array(p.args.prefix(4)), keys = ["store-dir", "cache-dir", "global-dir", "state-dir"]
            let version = run(p.environment + [p.executable, "--version"])
            guard version.0 == 0, let versionText = value(version.1), let majorText = versionText.split(separator: ".").first, let major = Int(majorText) else { return nil }
            var roots: [String] = [pnpmHome]
            for (flag, key) in zip(flags, keys) {
                let prefix = "--config." + key + "="
                guard flag.hasPrefix(prefix), let bound = root(String(flag.dropFirst(prefix.count)), home: home) else { return nil }
                let reported = run(p.environment + [p.executable] + flags + ["config", "get", key])
                guard reported.0 == 0 else { return nil }
                // pnpm 10's config getter omits CLI overrides. Those roots are pinned in argv;
                // the active store query below independently verifies the shared option parser.
                guard path(reported.1, home: home) == bound || (major == 10 && value(reported.1) == "undefined") else { return nil }
                roots.append(bound)
            }
            let store = roots[1]
            guard let active = query(flags + ["store", "path"]), active == store || active.hasPrefix(store + "/") else { return nil }
            let homeConfig = run(p.environment + [p.executable] + flags + ["config", "get", "pnpm-home-dir"])
            guard homeConfig.0 == 0, let homeValue = value(homeConfig.1) else { return nil }
            if homeValue != "undefined" {
                guard let configured = root(homeValue, home: home) else { return nil }; roots.append(configured)
            }
            return Array(Set(roots)).sorted()
        default: return nil
        }
    }

    static func runningRefusal(_ item: CleanItem, processes: ProcessTable) -> String? {
        guard ids.contains(item.id) else { return nil }
        guard processes.available else { return tr("Could not verify running apps; refresh before removing files") }
        let name = item.id == "go-mod-cache" ? "go" : item.id == "pnpm-store-prune" ? "pnpm" : "brew"
        if processes.running([name]) != nil { return tr("quit %1$@ first", name) }
        let scripts: Set<String> = name == "pnpm" ? ["pnpm", "pnpm.cjs", "pnpm.mjs", "pnpm.js"] : name == "brew" ? ["brew.rb"] : []
        if processes.entries.contains(where: { process in
            guard ["node", "ruby"].contains(process.name), let script = process.argv.dropFirst().first else { return false }
            return scripts.contains((script as NSString).lastPathComponent)
        }) { return tr("quit %1$@ first", name) }
        return nil
    }

    static func refusal(_ item: CleanItem, whitelist: Whitelist, home: String, run: Runner = { ManagedToolScope.read($0) }) -> String? {
        guard ids.contains(item.id) else { return nil }
        guard let reviewed = item.commandScope, !reviewed.isEmpty, let commands = item.commands, commands.count == 1,
              let actual = scope(commands[0], id: item.id, home: home, run: run),
              Set(reviewed) == Set(actual) else { return tr(unavailable) }
        if actual.contains(where: whitelist.protects) { return tr("Tool cleanup overlaps a whitelisted location; keep it protected or review the whitelist first.") }
        return nil
    }
}
