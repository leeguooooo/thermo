// Opt-in, read-only vendor acceptance. Link current Debug CleanKit/AgentCore/ThermoL10n
// objects with -I .build/out/Products/Debug -parse-as-library.
// Arguments: official pnpm executable, owned scratch parent. Never runs store prune.
@testable import CleanKit
import AgentCore
import Foundation

@main
struct ToolScopeAcceptance {
    struct Failure: LocalizedError { let errorDescription: String? }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(errorDescription: message) }
    }
    static func main() {
        do { try run() } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        guard CommandLine.arguments.count == 3 else { throw Failure(errorDescription: "usage: probe PNPM SCRATCH") }
        let binary = CommandLine.arguments[1], fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("scope-acceptance-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let work = root.appendingPathComponent("work"); try fm.createDirectory(at: work, withIntermediateDirectories: false)
        let directories = ["store-dir", "cache-dir", "global-dir", "state-dir", "pnpmHome"]
        for name in directories { try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false) }
        let empty = root.appendingPathComponent("empty.npmrc"), globalEmpty = root.appendingPathComponent("global.npmrc")
        try Data().write(to: empty); try Data().write(to: globalEmpty)
        var environment = ProcessInfo.processInfo.environment.filter { ["PATH", "TMPDIR", "LANG", "LC_ALL"].contains($0.key) }
        environment["XDG_CONFIG_HOME"] = root.appendingPathComponent("config").path
        environment["XDG_CACHE_HOME"] = root.appendingPathComponent("cache").path
        environment["XDG_DATA_HOME"] = root.appendingPathComponent("data").path
        environment["XDG_STATE_HOME"] = root.appendingPathComponent("state").path
        environment["NPM_CONFIG_USERCONFIG"] = empty.path
        environment["NPM_CONFIG_GLOBALCONFIG"] = globalEmpty.path
        let keys = ["store-dir", "cache-dir", "global-dir", "state-dir"]
        let flags = keys.map { "--config." + $0 + "=" + root.appendingPathComponent($0).path }
        let command = ["PNPM_HOME=" + root.appendingPathComponent("pnpmHome").path, binary] + flags + ["store", "prune"]
        var queries = 0, attemptedRemoval = false
        var lastQuery = ""
        let reader: ManagedToolScope.Runner = { argv in
            guard let parsed = ManagedToolScope.parts(argv),
                  parsed.args == ["--version"] || Array(parsed.args.suffix(2)) == ["store", "path"] ||
                    (parsed.args.count >= 3 && Array(parsed.args.suffix(3)).prefix(2) == ["config", "get"]) else {
                attemptedRemoval = true; return (-1, "cleanup is forbidden in this acceptance harness")
            }
            queries += 1
            let result = CommandRunner.run("/usr/bin/env", arguments: argv, directory: work.path, environment: environment, timeout: 15)
            lastQuery = Array(parsed.args.suffix(3)).joined(separator: " ") + " => " + String(result.status) + " " + String(result.output.prefix(700))
            return (result.status, result.output)
        }
        let version = reader([binary, "--version"])
        try require(version.0 == 0, "version probe failed")
        guard let scope = ManagedToolScope.scope(command, id: "pnpm-store-prune", home: root.path, run: reader) else { throw Failure(errorDescription: "vendor scope query failed: " + lastQuery) }
        try require(scope.count >= 5, "scope omitted an auxiliary directory")
        let owned = ManagedToolScope.systemSpelling(root.resolvingSymlinksInPath().path)
        try require(scope.allSatisfy { $0.hasPrefix(owned + "/") }, "scope escaped the owned scratch directory")
        let item = CleanItem(id: "pnpm-store-prune", category: .devCaches, title: "owned probe", safety: .safe, bytes: 1, commands: [command], commandScope: scope)
        let protected = Whitelist(file: root.appendingPathComponent("whitelist").path, entries: [root.appendingPathComponent("cache-dir/dlx/keep").path])
        try require(ManagedToolScope.refusal(item, whitelist: protected, home: root.path, run: reader) != nil, "auxiliary protection was bypassed")
        try require(ManagedToolScope.refusal(item, whitelist: Whitelist(file: "/fixture", entries: [root.appendingPathComponent("unrelated").path]), home: root.path, run: reader) == nil, "unrelated protection disabled pruning")
        try require(!attemptedRemoval, "a destructive command reached the reader")
        let report: [String: Any] = ["version": ManagedToolScope.value(version.1) ?? version.1, "scopeCount": scope.count, "queries": queries, "auxiliaryProtectionRefused": true, "unrelatedProtectionAllowed": true, "cleanupExecuted": false]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
