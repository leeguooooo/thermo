import Foundation
import ThermoL10n

/// A newer version of a plugin or skill than the one installed.
public struct ExtensionUpdate: Codable, Equatable, Sendable {
    public var installed: String
    public var available: String
}

/// What the last `thermo agents updates --check` learned about skills installed with the `skills`
/// CLI: the content hash of each skill's folder upstream. Kept so the check itself stays offline.
public struct SkillUpdateCache: Codable, Equatable, Sendable {
    public var checked: Date
    /// Skill name → folder hash upstream when checked.
    public var latest: [String: String]
    /// Skill name → why it could not be checked.
    public var failed: [String: String] = [:]

    public static func url(home: URL) -> URL { home.appendingPathComponent("Library/Caches/dev.thermo/skill-updates.json") }

    public static func load(home: URL) -> SkillUpdateCache? {
        guard let data = try? Data(contentsOf: url(home: home)), data.count < 4 << 20 else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(SkillUpdateCache.self, from: data)
    }

    public func save(home: URL) {
        let u = Self.url(home: home)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]
        try? e.encode(self).write(to: u, options: .atomic)
    }
}

/// One skill recorded in `~/.agents/.skill-lock.json` by the `skills` CLI.
struct LockedSkill: Equatable {
    var name: String
    var sourceType: String
    /// `owner/repo` for GitHub sources.
    var source: String
    var skillPath: String
    var folderHash: String
    var installed: Date?
}

extension ConfigChecks {
    /// Plugins and skills nobody has used for this long are offered for removal.
    static let unusedAfter: TimeInterval = 60 * 86400

    /// `1.2.10` > `1.2.9`; nil when either is not a dotted number.
    static func newer(_ a: String, than b: String) -> Bool? {
        func parts(_ v: String) -> [Int]? {
            let p = v.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) }
            return p.isEmpty || p.contains(nil) ? nil : p.map { $0! }
        }
        guard let x = parts(a), let y = parts(b) else { return nil }
        let n = max(x.count, y.count)
        let xp = x + Array(repeating: 0, count: n - x.count), yp = y + Array(repeating: 0, count: n - y.count)
        return yp.lexicographicallyPrecedes(xp)
    }

    /// The version a marketplace offers for one plugin: from its catalog entry, or from the
    /// plugin's own manifest when the catalog points into the marketplace folder.
    static func catalogVersion(_ plugin: String, marketplace: URL) -> String? {
        guard let data = try? Data(contentsOf: marketplace.appendingPathComponent(".claude-plugin/marketplace.json")), data.count < 16 << 20,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entry = (root["plugins"] as? [[String: Any]])?.first(where: { $0["name"] as? String == plugin }) else { return nil }
        if let v = entry["version"] as? String, !v.isEmpty { return v }
        guard let source = entry["source"] as? String, source.hasPrefix("./") || !source.contains(":") else { return nil }
        let folder = marketplace.appendingPathComponent(source).standardizedFileURL
        guard folder.path.hasPrefix(marketplace.standardizedFileURL.path + "/"),
              let manifest = try? Data(contentsOf: folder.appendingPathComponent(".claude-plugin/plugin.json")),
              let m = (try? JSONSerialization.jsonObject(with: manifest)) as? [String: Any] else { return nil }
        return m["version"] as? String
    }

    static func lockedSkills(_ url: URL) -> [LockedSkill] {
        guard let data = try? Data(contentsOf: url), data.count < 8 << 20,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let skills = root["skills"] as? [String: Any] else { return [] }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return skills.keys.sorted().compactMap { name in
            guard let s = skills[name] as? [String: Any] else { return nil }
            return LockedSkill(name: name, sourceType: s["sourceType"] as? String ?? "", source: s["source"] as? String ?? "",
                               skillPath: s["skillPath"] as? String ?? "", folderHash: s["skillFolderHash"] as? String ?? "",
                               installed: (s["installedAt"] as? String).flatMap(iso.date))
        }
    }

    /// `name → (count, last use)` from Claude Code's own counters in `~/.claude.json`.
    static func usage(_ value: Any?) -> [String: (count: Int, last: Date?)] {
        var out: [String: (count: Int, last: Date?)] = [:]
        for (name, v) in value as? [String: Any] ?? [:] {
            guard let o = v as? [String: Any] else { continue }
            let last = (o["lastUsedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            out[name] = ((o["usageCount"] as? NSNumber)?.intValue ?? 0, last)
        }
        return out
    }

    private func days(_ t: TimeInterval) -> String { String(Int(t / 86400)) }

    /// Updates and disuse of Claude Code plugins, skills installed with the `skills` CLI, and the
    /// plugins Codex has installed. Offline: plugin versions come from the marketplace catalogs
    /// Claude Code keeps, skill versions from the last `thermo agents updates --check`.
    mutating func checkExtensions() {
        guard !env.cancelled() else { return }
        let claudeJSON = env.json(env.url(".claude.json")) as? [String: Any] ?? [:]
        checkClaudePluginUpdates(usage: Self.usage(claudeJSON["pluginUsage"]))
        checkLockedSkills(usage: Self.usage(claudeJSON["skillUsage"]))
        checkCodexPlugins()
    }

    private mutating func checkClaudePluginUpdates(usage: [String: (count: Int, last: Date?)]) {
        let dir = env.url(".claude/plugins")
        guard let root = env.json(dir.appendingPathComponent("installed_plugins.json")) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any] else { return }
        let claude = env.resolve("claude")
        for (id, entries) in plugins.sorted(by: { $0.key < $1.key }) {
            guard !env.cancelled() else { return }
            guard let at = id.lastIndex(of: "@") else { continue }
            let name = String(id[..<at]), market = String(id[id.index(after: at)...])
            let available = Self.catalogVersion(name, marketplace: dir.appendingPathComponent("marketplaces/" + market))
            for e in entries as? [[String: Any]] ?? [] {
                let project = e["projectPath"] as? String
                let key = Redact.identifier("plugins|" + id + "|" + (project ?? ""))
                guard items.contains(where: { $0.id == key }) else { continue }
                currentItem = key
                defer { currentItem = nil }
                if let installed = e["version"] as? String, let available, Self.newer(available, than: installed) == true {
                    items[items.firstIndex { $0.id == key }!].update = ExtensionUpdate(installed: installed, available: available)
                    add(Finding(.info, .plugins, agent: "claude", subject: id, tr("update available: %1$@ → %2$@", installed, available),
                                fix: tr("update it; Claude Code loads the new version after a restart"), source: "~/.claude/plugins/installed_plugins.json"))
                    if let claude {
                        let scope = e["scope"] as? String ?? "user"
                        offer(.update, tr("Update"), tr("Runs Claude Code's own command to update %1$@ to %2$@. Sessions pick it up after a restart.", id, available),
                              [.run(tool: claude, args: ["plugin", "update", id, "-s", scope], cwd: project)], bulk: false)
                    }
                }
                if let last = usage[id]?.last, env.now.timeIntervalSince(last) > Self.unusedAfter {
                    add(Finding(.info, .plugins, agent: "claude", subject: id,
                                tr("not used in Claude Code for %1$@ days", days(env.now.timeIntervalSince(last))),
                                fix: tr("disable or uninstall it if you no longer need it"), source: "~/.claude.json"))
                }
            }
        }
    }

    private mutating func checkLockedSkills(usage: [String: (count: Int, last: Date?)]) {
        let skills = Self.lockedSkills(env.url(".agents/.skill-lock.json"))
        guard !skills.isEmpty else { return }
        let cache = SkillUpdateCache.load(home: env.home)
        let npx = env.resolve("npx")
        for s in skills {
            guard !env.cancelled() else { return }
            // The skill as Claude Code sees it; the same folder is linked into other agents too.
            guard let i = items.firstIndex(where: { $0.area == .skills && $0.agent == "claude" && $0.name == s.name }) else { continue }
            let key = items[i].id
            currentItem = key
            defer { currentItem = nil }
            if let latest = cache?.latest[s.name], !s.folderHash.isEmpty, latest != s.folderHash {
                items[i].update = ExtensionUpdate(installed: String(s.folderHash.prefix(7)), available: String(latest.prefix(7)))
                add(Finding(.info, .skills, agent: "claude", subject: s.name,
                            tr("a newer version is published at %1$@", s.source), fix: tr("update it with the skills tool"),
                            source: "~/.agents/.skill-lock.json"))
                if let npx {
                    offer(.update, tr("Update"), tr("Runs npx skills update %1$@ for every agent it is installed in.", s.name),
                          [.run(tool: npx, args: ["-y", "skills", "update", s.name, "-g", "-y"], cwd: env.home.path)], bulk: false)
                }
            }
            if let npx {
                // Through the tool that installed it, so its record and every agent's link go together.
                let action = Action(id: key + "|uninstall|skills", kind: .uninstall, title: tr("Uninstall"),
                                    summary: Redact.text(tr("Runs npx skills remove %1$@, which removes it from every agent and from the skills record.", s.name)),
                                    steps: [.run(tool: npx, args: ["-y", "skills", "remove", s.name, "-g", "-y"], cwd: env.home.path)],
                                    destructive: true, bulk: false)
                items[i].actions.insert(action, at: 0)
            }
            let installedLongAgo = s.installed.map { env.now.timeIntervalSince($0) > Self.unusedAfter } ?? false
            if installedLongAgo {
                if let last = usage[s.name]?.last {
                    if env.now.timeIntervalSince(last) > Self.unusedAfter {
                        add(Finding(.info, .skills, agent: "claude", subject: s.name,
                                    tr("not used in Claude Code for %1$@ days", days(env.now.timeIntervalSince(last))),
                                    fix: tr("uninstall it if you no longer need it; every installed skill's description is loaded into each session"),
                                    source: "~/.claude.json"))
                    }
                } else {
                    add(Finding(.info, .skills, agent: "claude", subject: s.name, tr("never used in Claude Code since it was installed"),
                                fix: tr("uninstall it if you no longer need it; every installed skill's description is loaded into each session"),
                                source: "~/.claude.json"))
                }
            }
        }
    }

    /// Codex records its plugins as `[plugins."<id>"]` tables with `enabled = …`; it removes
    /// them with `codex plugin remove`.
    private mutating func checkCodexPlugins() {
        guard let toml = try? String(contentsOf: env.url(".codex/config.toml"), encoding: .utf8) else { return }
        let codex = env.resolve("codex")
        var current: String?
        var plugins: [(id: String, enabled: Bool)] = []
        for raw in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = line.hasPrefix("[plugins.\"") && line.hasSuffix("\"]") ? String(line.dropFirst("[plugins.\"".count).dropLast(2)) : nil
                if let current { plugins.append((current, true)) }
            } else if current != nil, line.replacingOccurrences(of: " ", with: "") == "enabled=false" {
                plugins[plugins.count - 1].enabled = false
            }
        }
        for p in plugins {
            guard !env.cancelled() else { return }
            item(.plugins, agent: "codex", id: "codex|" + p.id, name: p.id, detail: p.enabled ? tr("enabled") : tr("disabled"),
                 source: "~/.codex/config.toml", enabled: p.enabled)
            defer { currentItem = nil }
            if let codex {
                offer(.uninstall, tr("Uninstall"), tr("Runs Codex's own command to uninstall %1$@ and remove its cache.", p.id),
                      [.run(tool: codex, args: ["plugin", "remove", p.id], cwd: nil)], bulk: false)
            }
        }
    }
}

/// Looks up, on GitHub, the current folder hash of every skill the `skills` CLI installed from
/// there; that hash is what its lock file records at install time. One small request per folder
/// that holds skills, through `gh` when it is signed in (higher rate limit), otherwise curl.
public enum SkillUpdates {
    public static func check(_ env: DoctorEnvironment) -> SkillUpdateCache {
        var cache = SkillUpdateCache(checked: env.now, latest: [:])
        let skills = ConfigChecks.lockedSkills(env.url(".agents/.skill-lock.json")).filter {
            $0.sourceType == "github" && $0.source.split(separator: "/").count == 2 && !$0.folderHash.isEmpty
        }
        let gh = env.resolve("gh")
        func get(_ path: String) -> Any? {
            let out = gh.flatMap { env.run($0, ["api", path]) }
                ?? env.run("/usr/bin/curl", ["-fsSL", "--max-time", "10", "-H", "Accept: application/vnd.github+json", "https://api.github.com/" + path])
            return out.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        }
        // Skills sharing a parent folder in one repository are answered by one listing.
        let groups = Dictionary(grouping: skills) { s -> String in
            let folder = (s.skillPath as NSString).deletingLastPathComponent
            return s.source + "|" + (folder.isEmpty ? "" : (folder as NSString).deletingLastPathComponent) + "|" + (folder.isEmpty ? "root" : "dir")
        }
        for (_, group) in groups.sorted(by: { $0.key < $1.key }) {
            if env.cancelled() { break }
            let first = group[0]
            let folder = (first.skillPath as NSString).deletingLastPathComponent
            if folder.isEmpty {
                guard let sha = (get("repos/\(first.source)/git/trees/HEAD") as? [String: Any])?["sha"] as? String else {
                    for s in group { cache.failed[s.name] = "github unreachable" }
                    continue
                }
                for s in group { cache.latest[s.name] = sha }
            } else {
                let parent = (folder as NSString).deletingLastPathComponent
                let path = parent.isEmpty ? "repos/\(first.source)/contents" : "repos/\(first.source)/contents/\(parent)"
                guard let entries = get(path) as? [[String: Any]] else {
                    for s in group { cache.failed[s.name] = "github unreachable" }
                    continue
                }
                for s in group {
                    let name = ((s.skillPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
                    if let sha = entries.first(where: { $0["name"] as? String == name && $0["type"] as? String == "dir" })?["sha"] as? String {
                        cache.latest[s.name] = sha
                    } else { cache.failed[s.name] = "folder no longer published" }
                }
            }
        }
        return cache
    }
}
