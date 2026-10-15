import Foundation

/// Developer caches whose tool has its own clean command. The tool knows its locks, its layout and
/// what is still in use, so its command runs instead of deleting the folder; when the tool is
/// missing (or the whitelist keeps something inside) the folder is deleted as before.
/// Cargo has no cache-clean command and Homebrew's `brew cleanup` also prunes the Cellar (its own
/// item), so their folders are still deleted.
enum NativeCleanup {
    struct Spec {
        let rule: String
        /// Program names, in order of preference (`pip3` before `pip`).
        let names: [String]
        let display: String
        /// The folders the command empties, as the rule names them.
        let folders: [String]
        /// Settings and arguments for one folder; the program goes between them.
        let command: (_ folder: String) -> (env: [String], args: [String])
        /// Whether a resolved program can do it (Yarn 2+ cleans only inside a project).
        var usable: (_ program: String) -> Bool = { _ in true }
    }

    static let specs: [Spec] = [
        // npm keeps its cache in `<cache>/_cacache`; logs are not part of `cache clean` and are deleted.
        Spec(rule: "npm-cache", names: ["npm"], display: "npm cache clean --force", folders: ["~/.npm/_cacache"],
             command: { ([], ["cache", "clean", "--force", "--cache", ($0 as NSString).deletingLastPathComponent]) }),
        // Yarn 1 appends `v6` to `--cache-folder`.
        Spec(rule: "yarn-cache", names: ["yarn"], display: "yarn cache clean", folders: ["~/Library/Caches/Yarn/v6"],
             command: { ([], ["cache", "clean", "--cache-folder", ($0 as NSString).deletingLastPathComponent]) },
             usable: isYarnClassic),
        Spec(rule: "pip-cache", names: ["pip3", "pip"], display: "pip cache purge", folders: ["~/Library/Caches/pip", "~/.cache/pip"],
             command: { (["PIP_DISABLE_PIP_VERSION_CHECK=1", "PIP_NO_INPUT=1"], ["cache", "purge", "--cache-dir", $0]) }),
        Spec(rule: "uv-cache", names: ["uv"], display: "uv cache clean", folders: ["~/.cache/uv", "~/Library/Caches/uv"],
             command: { ([], ["cache", "clean", "--cache-dir", $0]) }),
        Spec(rule: "go-cache", names: ["go"], display: "go clean -cache", folders: ["~/Library/Caches/go-build"],
             command: { (["GOCACHE=" + $0], ["clean", "-cache"]) }),
    ]

    static func spec(_ rule: String) -> Spec? { specs.first { $0.rule == rule } }

    // MARK: Finding the tool

    /// Tests point this at fake programs; nil uses `searchDirectories(home:)`.
    nonisolated(unsafe) static var searchOverride: [String]? = nil

    /// Fixed places only, never the user's shell setup: an app opened from the Finder has no PATH,
    /// and running shell startup files would run whatever is in them.
    static func searchDirectories(home: String) -> [String] {
        if let searchOverride { return searchOverride }
        let h = { FS.expand($0, home: home) }
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", h("~/.local/bin"), h("~/.cargo/bin"), h("~/.volta/bin"),
                    "/usr/local/go/bin", h("~/go/bin")]
        dirs += [h("~/Library/Application Support/fnm/aliases/default/bin"), h("~/.local/share/fnm/aliases/default/bin")]
        if let nvm = nvmDefault(home: home) { dirs.append(nvm) }
        return dirs
    }

    /// nvm's default Node from `~/.nvm/alias/default` ("22", "v22.3.0"; aliases such as `lts/*`
    /// take the newest installed), read from disk.
    static func nvmDefault(home: String) -> String? {
        let versions = FS.expand("~/.nvm/versions/node", home: home)
        let installed = (try? FileManager.default.contentsOfDirectory(atPath: versions))?.filter { $0.hasPrefix("v") } ?? []
        guard !installed.isEmpty else { return nil }
        let alias = (try? String(contentsOfFile: FS.expand("~/.nvm/alias/default", home: home), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let wanted = alias.hasPrefix("v") ? alias : "v" + alias
        func parts(_ v: String) -> [Int] { v.dropFirst().split(separator: ".").map { Int($0) ?? 0 } }
        let newestFirst = installed.sorted { parts($0).lexicographicallyPrecedes(parts($1)) }.reversed()
        let pick = installed.contains(wanted) ? wanted
            : newestFirst.first { $0.hasPrefix(wanted + ".") } ?? newestFirst.first!
        return versions + "/" + pick + "/bin"
    }

    static func resolve(_ names: [String], in dirs: [String]) -> String? {
        for name in names {
            for dir in dirs {
                let p = dir + "/" + name
                if FileManager.default.isExecutableFile(atPath: p), !FS.isDirectory(p) { return p }
            }
        }
        return nil
    }

    /// Yarn 1 (`yarn cache clean` empties the global cache). Found from the package it belongs to;
    /// the program itself is not run (a Corepack shim would download Yarn first).
    static func isYarnClassic(_ program: String) -> Bool {
        var dir = (URL(fileURLWithPath: program).resolvingSymlinksInPath().path as NSString).deletingLastPathComponent
        for _ in 0..<4 {
            for candidate in [dir + "/package.json", dir + "/libexec/package.json"] {
                guard let data = FileManager.default.contents(atPath: candidate),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                return json["name"] as? String == "yarn" && (json["version"] as? String)?.hasPrefix("1.") == true
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return false
    }

    // MARK: Scanning

    /// Adds the tool's command to a rule's item, for the folders the item actually covers.
    static func attach(_ item: CleanItem, home: String, dirs: [String]? = nil) -> CleanItem {
        guard let spec = spec(item.id) else { return item }
        let folders = spec.folders.map { FS.expand($0, home: home) }.filter { folder in
            item.paths.contains { $0 == folder || $0.hasPrefix(folder + "/") }
        }
        guard !folders.isEmpty else { return item }
        var out = item
        let tool = spec.names[0]
        guard let program = resolve(spec.names, in: dirs ?? searchDirectories(home: home)), spec.usable(program) else {
            let why = tr("%1$@ was not found in the standard locations; the folder is deleted instead", tool)
            out.native = NativeClean(tool: tool, display: spec.display, runs: [], fallback: why, fallbackStatus: "notFound")
            out.note = [item.note, why].compactMap { $0 }.joined(separator: tr("; "))
            return out
        }
        // Node-based tools start with `#!/usr/bin/env node`: their own folder comes first on PATH.
        let path = "PATH=" + ([(program as NSString).deletingLastPathComponent] + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ":")
        let runs = folders.map { folder -> NativeClean.Run in
            let c = spec.command(folder)
            return NativeClean.Run(folder: folder, argv: [path] + c.env + [program] + c.args)
        }
        out.native = NativeClean(tool: (program as NSString).lastPathComponent, display: spec.display, runs: runs)
        return out
    }

    // MARK: Cleaning

    /// Runs the item's tool commands. Returns the folders the tool took over (their paths are not
    /// deleted, also when the command failed: a failing tool is a reason to stop, not to delete
    /// behind it). Folders the tool cannot handle are left to the normal deletion.
    static func perform(_ item: CleanItem, mode: RemovalMode, guard g: Guard, whitelist: Whitelist,
                        refusal: () -> String?, openFiles: () -> OpenFiles?, operations: RemovalOperations,
                        result: inout CleanResult) -> [String] {
        guard let native = item.native else { return [] }
        var outcomes: [ToolCommandOutcome] = []
        defer { if !outcomes.isEmpty { result.toolCommands = (result.toolCommands ?? []) + outcomes } }
        if native.runs.isEmpty {
            outcomes.append(ToolCommandOutcome(tool: native.tool, command: native.display, status: native.fallbackStatus ?? "notFound",
                                               detail: native.fallback, fellBack: true))
            return []
        }
        var handled: [String] = []
        for run in native.runs {
            var o = ToolCommandOutcome(tool: native.tool, command: run.commandLine, folder: run.folder, status: "ran")
            func fallBack(_ status: String, _ why: String) { o.status = status; o.detail = why; o.fellBack = true; outcomes.append(o) }
            func stop(_ status: String, _ why: String) {
                o.status = status; o.detail = why; outcomes.append(o)
                result.failed[run.commandLine] = why; handled.append(run.folder)
            }
            if mode.trashes(item.safety) { fallBack("trash", tr("the Trash was chosen, so the folder is moved there instead")); continue }
            if whitelist.protects(run.folder) { fallBack("whitelisted", tr("the whitelist keeps something inside; folders are deleted one by one instead")); continue }
            if let why = g.refusal(run.folder) { fallBack("refused", why); continue }
            guard let program = run.executable, FileManager.default.isExecutableFile(atPath: program) else {
                fallBack("notFound", tr("%1$@ was not found in the standard locations; the folder is deleted instead", native.tool)); continue
            }
            guard FS.exists(run.folder) else { continue }
            if let scanned = item.identities?[run.folder], FileIdentity.of(run.folder) != scanned {
                stop("refused", tr("replaced since the scan")); continue
            }
            if let why = refusal() { stop("refused", why); continue }
            guard let snapshot = openFiles() else { stop("refused", tr("could not check whether a program is using it")); continue }
            if let holder = snapshot.holder(of: run.folder) { stop("refused", tr("%1$@ has files open here", holder.name)); continue }
            let before = FS.size(run.folder)
            let (status, output) = operations.run(run.argv, operations.commandTimeout)
            let after = FS.size(run.folder)
            let measured = !(before.denied || before.incomplete || after.denied || after.incomplete)
            o.bytesBefore = measured ? before.bytes : nil
            o.bytesAfter = measured ? after.bytes : nil
            o.exitCode = status
            let freed = max(0, before.bytes - after.bytes)
            if measured { result.bytes += freed } else { result.bytesIncomplete = true }
            if status == 0 {
                outcomes.append(o)
                result.removed.append("ran: " + run.commandLine)
                handled.append(run.folder)
            } else {
                stop(output == "timed out" ? "timedOut" : output == "cancelled" ? "cancelled" : "failed",
                     output.isEmpty ? "exit \(status)" : String(output.suffix(2000)))
                if freed > 0 || !measured { result.partialRemoved = (result.partialRemoved ?? []) + [run.folder] }
            }
        }
        return handled
    }
}

/// What happened to one tool command, for the result, the log and the operation history.
public struct ToolCommandOutcome: Codable, Sendable, Equatable {
    public var tool: String
    /// The exact line that ran (or would have).
    public var command: String
    public var folder: String?
    /// ran | failed | timedOut | cancelled | refused | notFound | whitelisted | trash
    public var status: String
    public var detail: String?
    public var exitCode: Int32?
    /// Measured private bytes before and after; nil when not measured or not measurable.
    public var bytesBefore: Int64?
    public var bytesAfter: Int64?
    /// The folder was left to the normal deletion instead.
    public var fellBack: Bool?

    public init(tool: String, command: String, folder: String? = nil, status: String, detail: String? = nil, fellBack: Bool? = nil) {
        self.tool = tool; self.command = command; self.folder = folder; self.status = status; self.detail = detail; self.fellBack = fellBack
    }
}
