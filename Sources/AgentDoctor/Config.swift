import Foundation
import ThermoL10n

struct MCPServer: Equatable {
    var name: String
    var agent: String
    var source: String
    var command: String?
    var args: [String] = []
    var env: [String: String] = [:]
    var url: String?
    var headers: [String: String] = [:]
    var disabled = false
    /// Set for servers configured for one project only.
    var project: String?
}

struct HookCommand {
    var agent: String
    var source: String
    var event: String
    var matcher: String?
    var command: String
    var timeout: Double?
    var runsInBackground = false
    var conditional = false
    /// Position in the file, so the exact entry can be removed.
    var group = 0
    var index = 0
    /// Variables the agent sets for this hook, e.g. CLAUDE_PLUGIN_ROOT.
    var vars: [String: String] = [:]
}

struct InstalledPlugin {
    var id: String
    var installPath: String
    var scope: String
    var projectPath: String?
}

/// Reads every agent's configuration from disk and checks it without running anything.
struct ConfigChecks {
    let env: DoctorEnvironment
    var findings: [Finding] = []
    var inventory = Inventory()
    var servers: [MCPServer] = []

    init(env: DoctorEnvironment) { self.env = env }

    var items: [AgentItem] = []
    /// Findings reported while this is set belong to that item.
    var currentItem: String?

    mutating func add(_ f: Finding) {
        var f = f
        if f.item == nil { f.item = currentItem }
        findings.append(f)
    }

    /// Registers an item and makes it current; returns its id.
    @discardableResult
    mutating func item(_ area: Area, agent: String, id: String, name: String, detail: String,
                       source: String?, enabled: Bool = true) -> String {
        let key = Redact.identifier("\(area.rawValue)|\(id)")
        if !items.contains(where: { $0.id == key }) {
            items.append(AgentItem(id: key, area: area, agent: Redact.text(agent), name: Redact.text(name), detail: Redact.text(String(detail.prefix(200))),
                                   source: source.map(Redact.text), enabled: enabled))
        }
        currentItem = key
        return key
    }

    mutating func runAll() {
        let claudeDir = env.url(".claude")
        if env.exists(claudeDir.path) { inventory.agents.append("claude") }
        if env.exists(env.url(".codex").path) { inventory.agents.append("codex") }
        if env.exists(env.url(".cursor").path) { inventory.agents.append("cursor") }
        if env.exists(env.url(".gemini").path) { inventory.agents.append("gemini") }

        var claudeSettings: [String: Any] = [:]
        for name in ["settings.json", "settings.local.json"] {
            let u = claudeDir.appendingPathComponent(name)
            guard env.exists(u.path) else { continue }
            guard let s = env.json(u) as? [String: Any] else {
                add(Finding(.error, .hooks, agent: "claude", subject: name, tr("settings file is not valid JSON; Claude Code ignores all of it"),
                            fix: tr("fix the syntax in %1$@", env.short(u.path)), source: env.short(u.path)))
                continue
            }
            checkHooks(s["hooks"], agent: "claude", source: u)
            if let sl = s["statusLine"] as? [String: Any] { checkStatusLine(sl, source: u) }
            claudeSettings.merge(s) { a, _ in a }
        }

        let claudeJSON = env.url(".claude.json")
        if let cj = env.json(claudeJSON) as? [String: Any] {
            servers += Self.jsonServers(cj["mcpServers"], agent: "claude", source: env.short(claudeJSON.path))
            for (path, p) in (cj["projects"] as? [String: Any]) ?? [:] {
                let ps = Self.jsonServers((p as? [String: Any])?["mcpServers"], agent: "claude", source: env.short(claudeJSON.path))
                servers += ps.map { var s = $0; s.project = path; return s }
            }
        }

        checkPlugins(enabled: claudeSettings["enabledPlugins"] as? [String: Any] ?? [:])
        currentItem = nil

        // Codex
        let codexDir = env.url(".codex")
        let toml = codexDir.appendingPathComponent("config.toml")
        if let text = try? String(contentsOf: toml, encoding: .utf8) {
            servers += Self.tomlServers(text, source: env.short(toml.path))
        }
        let codexHooks = codexDir.appendingPathComponent("hooks.json")
        if env.exists(codexHooks.path) {
            if let h = env.json(codexHooks) as? [String: Any] { checkHooks(h["hooks"], agent: "codex", source: codexHooks) }
            else { add(Finding(.error, .hooks, agent: "codex", subject: "hooks.json", tr("hooks file is not valid JSON"), source: env.short(codexHooks.path))) }
        }

        // Cursor, Gemini
        let cursor = env.url(".cursor/mcp.json")
        if let c = env.json(cursor) as? [String: Any] {
            servers += Self.jsonServers(c["mcpServers"], agent: "cursor", source: env.short(cursor.path))
        }
        let gemini = env.url(".gemini/settings.json")
        if let g = env.json(gemini) as? [String: Any] {
            servers += Self.jsonServers(g["mcpServers"], agent: "gemini", source: env.short(gemini.path))
            checkHooks(g["hooks"], agent: "gemini", source: gemini)
        }

        servers.forEach { checkServer($0) }
        inventory.mcpServers = servers.filter { !$0.disabled }.count

        checkSkills()
        currentItem = nil
    }

    // MARK: hooks

    static func hookCommands(_ value: Any?, agent: String, source: String) -> [HookCommand] {
        guard let events = value as? [String: Any] else { return [] }
        var out: [HookCommand] = []
        for (event, groups) in events.sorted(by: { $0.key < $1.key }) {
            for (gi, g) in (groups as? [[String: Any]] ?? []).enumerated() {
                let matcher = g["matcher"] as? String
                for (hi, h) in (g["hooks"] as? [[String: Any]] ?? []).enumerated() {
                    guard let cmd = h["command"] as? String else { continue }
                    // Gemini CLI takes hook timeouts in milliseconds; Claude Code and Codex in seconds.
                    let timeout = (h["timeout"] as? NSNumber).map { agent == "gemini" ? $0.doubleValue / 1000 : $0.doubleValue }
                    out.append(HookCommand(agent: agent, source: source, event: event, matcher: matcher, command: cmd, timeout: timeout,
                                           runsInBackground: (h["async"] as? Bool) == true || (h["asyncRewake"] as? Bool) == true,
                                           conditional: h["if"] != nil,
                                           group: gi, index: hi))
                }
            }
        }
        return out
    }

    mutating func checkHooks(_ value: Any?, agent: String, source: URL, vars: [String: String] = [:]) {
        let hooks = Self.hookCommands(value, agent: agent, source: env.short(source.path)).map { h -> HookCommand in
            var h = h; h.vars = vars; return h
        }
        inventory.hooks += hooks.count
        for (i, h) in hooks.enumerated() {
            let name = h.event + (h.matcher.map { $0.isEmpty || $0 == "*" ? "" : " [\($0)]" } ?? "")
            item(.hooks, agent: agent, id: "\(h.source)#\(i)", name: name, detail: h.command, source: h.source)
            // Hooks shipped inside a plugin are removed by disabling the plugin, not by editing its files.
            if vars.isEmpty {
                offer(.uninstall, tr("Remove hook"), tr("Deletes this %1$@ hook from %2$@. The file is backed up first.", h.event, h.source),
                      [.removeHook(file: source.path, event: h.event, group: h.group, hook: h.index, command: h.command)])
            }
            check(h)
        }
        currentItem = nil

        // Configuration describes possible overhead, not a measured execution trace.
        let perTool = hooks.filter { ($0.event == "PreToolUse" || $0.event == "PostToolUse")
            && !($0.runsInBackground || $0.conditional) && ["*", ".*", ""].contains($0.matcher ?? "*") }
        if perTool.count >= 4 {
            add(Finding(.info, .hooks, agent: agent, subject: "PreToolUse/PostToolUse",
                        tr("%1$@ synchronous command hooks have broad tool-call matchers; when enabled, they may add latency", String(perTool.count)),
                        fix: tr("narrow the matcher (e.g. \"Bash\" or \"Write|Edit\") or merge hooks that do the same thing"),
                        source: env.short(source.path)))
        }
    }

    mutating func check(_ h: HookCommand) {
        let guarded = Shell.isGuarded(h.command)
        let subject = h.event + (h.matcher.map { $0.isEmpty || $0 == "*" ? "" : " [\($0)]" } ?? "")
        for program in Shell.programs(h.command) {
            let p = env.expand(program, vars: h.vars)
            if p.contains("$") { continue }  // depends on a variable we can't know
            guard env.resolve(p) == nil else { continue }
            let what = p.contains("/") ? env.short(p) : tr("'%1$@' (not on PATH)", p)
            if guarded {
                add(Finding(.info, .hooks, agent: h.agent, subject: subject,
                            tr("hook is a no-op here: %1$@ does not exist and the command checks for it first", what),
                            fix: tr("remove it if that tool is no longer installed"), source: h.source))
            } else {
                add(Finding(.error, .hooks, agent: h.agent, subject: subject,
                            tr("hook references %1$@, which does not exist; it may fail when invoked for %2$@", what, h.event),
                            fix: tr("reinstall the tool or remove the hook"), source: h.source))
            }
        }
        if let t = h.timeout, t > 600, !h.runsInBackground {
            add(Finding(.info, .hooks, agent: h.agent, subject: subject,
                        tr("configured timeout is %1$@; review long-running synchronous hooks", Self.duration(t)),
                        source: h.source))
        }
    }

    // MARK: statusLine

    mutating func checkStatusLine(_ sl: [String: Any], source: URL) {
        guard let cmd = sl["command"] as? String else { return }
        item(.statusline, agent: "claude", id: source.path, name: "statusLine", detail: cmd, source: env.short(source.path))
        defer { currentItem = nil }
        offer(.uninstall, tr("Remove status line"), tr("Removes statusLine from %1$@. The file is backed up first.", env.short(source.path)),
              [.removeJSONKey(file: source.path, path: ["statusLine"])])
        for program in Shell.programs(cmd) {
            let p = env.expand(program)
            if !p.contains("$"), env.resolve(p) == nil {
                add(Finding(.error, .statusline, agent: "claude", subject: "statusLine",
                            tr("status line runs %1$@, which does not exist; the status bar stays empty", env.short(p)),
                            fix: tr("reinstall it or remove statusLine from settings"), source: env.short(source.path)))
            }
        }
        if let r = (sl["refreshInterval"] as? NSNumber)?.doubleValue, r > 0, r < 5 {
            add(Finding(.info, .statusline, agent: "claude", subject: "statusLine",
                        tr("refreshInterval %1$@ s spawns the status command %2$@ times a minute in every open session", String(Int(r)), String(Int(60 / r))),
                        source: env.short(source.path)))
        }
    }

    // MARK: MCP

    static func jsonServers(_ value: Any?, agent: String, source: String) -> [MCPServer] {
        guard let dict = value as? [String: Any] else { return [] }
        return dict.sorted { $0.key < $1.key }.compactMap { name, v in
            guard let s = v as? [String: Any] else { return nil }
            return MCPServer(name: name, agent: agent, source: source,
                             command: s["command"] as? String,
                             args: s["args"] as? [String] ?? [],
                             env: (s["env"] as? [String: Any] ?? [:]).compactMapValues { "\($0)" },
                             url: (s["url"] ?? s["httpUrl"] ?? s["serverUrl"]) as? String,
                             headers: (s["headers"] as? [String: Any] ?? [:]).compactMapValues { "\($0)" },
                             disabled: (s["disabled"] as? Bool) == true || (s["enabled"] as? Bool) == false)
        }
    }

    /// Just enough TOML for Codex's `[mcp_servers.<name>]` tables: string, bool and string-array values.
    static func tomlServers(_ text: String, source: String) -> [MCPServer] {
        var servers: [String: MCPServer] = [:]
        var order: [String] = []
        var current: String?
        var sub: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = nil; sub = nil
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                guard header.hasPrefix("mcp_servers.") else { continue }
                var parts = tomlKeyPath(String(header.dropFirst("mcp_servers.".count)))
                guard !parts.isEmpty else { continue }
                let name = parts.removeFirst()
                if servers[name] == nil {
                    servers[name] = MCPServer(name: name, agent: "codex", source: source)
                    order.append(name)
                }
                current = name
                sub = parts.first
                continue
            }
            guard let name = current, let eq = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch (sub, key) {
            case ("env", _): servers[name]?.env[key] = tomlString(value) ?? value
            case ("http_headers", _), ("headers", _): servers[name]?.headers[key] = tomlString(value) ?? value
            case (nil, "command"): servers[name]?.command = tomlString(value)
            case (nil, "url"): servers[name]?.url = tomlString(value)
            case (nil, "args"): servers[name]?.args = tomlArray(value)
            case (nil, "enabled"): servers[name]?.disabled = value.hasPrefix("false")
            case (nil, "bearer_token"): servers[name]?.headers["bearer_token"] = tomlString(value)
            default: break
            }
        }
        return order.compactMap { servers[$0] }
    }

    static func tomlKeyPath(_ s: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        var quoted = false
        for c in s {
            if c == "\"" { quoted.toggle() } else if c == "." && !quoted { parts.append(cur); cur = "" } else { cur.append(c) }
        }
        parts.append(cur)
        return parts
    }

    static func tomlString(_ v: String) -> String? {
        guard let q = v.first, q == "\"" || q == "'" else { return nil }
        let body = v.dropFirst()
        guard let end = body.firstIndex(of: q) else { return nil }
        return String(body[..<end])
    }

    static func tomlArray(_ v: String) -> [String] {
        guard v.hasPrefix("[") else { return [] }
        var out: [String] = []
        var cur = ""
        var quote: Character?
        for c in v.dropFirst() {
            if let q = quote { if c == q { out.append(cur); cur = ""; quote = nil } else { cur.append(c) } }
            else if c == "\"" || c == "'" { quote = c }
            else if c == "]" { break }
        }
        return out
    }

    mutating func checkServer(_ s: MCPServer) {
        let subject = s.project.map { "\(s.name) (\(env.short($0)))" } ?? s.name
        item(.mcp, agent: s.agent, id: "\(s.agent)|\(s.source)|\(s.project ?? "")|\(s.name)", name: subject,
             detail: s.url ?? ([s.command ?? ""] + s.args).joined(separator: " "), source: s.source, enabled: !s.disabled)
        defer { currentItem = nil }
        offerRemoval(s)
        guard !s.disabled else { return }

        if let project = s.project, !env.exists(project) {
            add(Finding(.info, .mcp, agent: s.agent, subject: subject,
                        tr("configured for a project directory that no longer exists"),
                        fix: tr("remove the entry from projects in %1$@", s.source), source: s.source))
            return
        }

        if let cmd = s.command {
            let p = env.expand(cmd)
            if !p.contains("$"), env.resolve(p) == nil {
                add(Finding(.error, .mcp, agent: s.agent, subject: subject,
                            tr("server command %1$@ does not exist; the server fails to start in every session", p.contains("/") ? env.short(p) : tr("'%1$@' (not on PATH)", p)),
                            fix: tr("reinstall it, fix the path, or remove the server"), source: s.source))
            }
            let launcher = (p as NSString).lastPathComponent
            if ["npx", "bunx", "uvx", "pnpx"].contains(launcher) || (launcher == "npm" && s.args.first == "exec") {
                if let pkg = s.args.first(where: { $0.hasSuffix("@latest") }) {
                    add(Finding(.info, .mcp, agent: s.agent, subject: subject,
                                tr("%1$@ resolves %2$@ from the registry on every start: slower startups, and the code can change under you", launcher, pkg),
                                fix: tr("pin a version or install it globally"), source: s.source))
                }
            }
        } else if s.url == nil {
            add(Finding(.error, .mcp, agent: s.agent, subject: subject, tr("server has neither a command nor a url"), source: s.source))
        }

        var secrets: [String] = []
        for (k, v) in s.env.sorted(by: { $0.key < $1.key }) where Redact.isSecretName(k) && Redact.isLiteralSecret(v) {
            secrets.append(tr("env %1$@", k + "=" + Redact.value(v)))
        }
        for (k, v) in s.headers.sorted(by: { $0.key < $1.key }) where Redact.isLiteralSecret(v.replacingOccurrences(of: "Bearer ", with: "")) {
            if Redact.isSecretName(k) || v.hasPrefix("Bearer ") { secrets.append(tr("header %1$@", k)) }
        }
        for (i, a) in s.args.enumerated() where i + 1 < s.args.count && a.hasPrefix("-") && Redact.isSecretName(a) && Redact.isLiteralSecret(s.args[i + 1]) {
            secrets.append(tr("argument %1$@", a))
        }
        if !secrets.isEmpty {
            add(Finding(.warning, .mcp, agent: s.agent, subject: subject,
                        tr("credential stored in plain text in the config (%1$@); arguments are also visible to every process via ps", secrets.joined(separator: ", ")),
                        fix: tr("move it to the keychain or an environment variable the agent inherits, then rotate it"), source: s.source))
        }
    }

    // MARK: plugins

    mutating func checkPlugins(enabled: [String: Any]) {
        let dir = env.url(".claude/plugins")
        let manifest = dir.appendingPathComponent("installed_plugins.json")
        guard env.exists(manifest.path) else { return }
        guard let root = env.json(manifest) as? [String: Any] else {
            add(Finding(.error, .plugins, agent: "claude", subject: "installed_plugins.json", tr("plugin manifest is not valid JSON"),
                        source: env.short(manifest.path)))
            return
        }
        var installed: [InstalledPlugin] = []
        for (id, entries) in (root["plugins"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            for e in entries as? [[String: Any]] ?? [] {
                guard let path = e["installPath"] as? String else { continue }
                installed.append(InstalledPlugin(id: id, installPath: path, scope: e["scope"] as? String ?? "user",
                                                 projectPath: e["projectPath"] as? String))
            }
        }
        let known = Set(((env.json(dir.appendingPathComponent("known_marketplaces.json")) as? [String: Any]) ?? [:]).keys)
        let isOn = { (id: String) in (enabled[id] as? Bool) == true }
        let installedIds = Set(installed.map(\.id))
        inventory.plugins = installedIds.filter(isOn).count
        let pluginKeys = installed.map { p in
            item(.plugins, agent: "claude", id: p.id + "|" + (p.projectPath ?? ""),
                 name: p.id + (p.projectPath.map { " (\(env.short($0)))" } ?? ""),
                 detail: env.short(p.installPath), source: env.short(manifest.path), enabled: isOn(p.id))
        }

        for (id, on) in enabled.sorted(by: { $0.key < $1.key }) where (on as? Bool) == true {
            if let i = installed.firstIndex(where: { $0.id == id }) {
                currentItem = pluginKeys[i]
            } else {
                item(.plugins, agent: "claude", id: id + "|", name: id, detail: tr("enabled, not installed"), source: "~/.claude/settings.json")
                if let claude = env.resolve("claude") {
                    offer(.fix, tr("Install"), tr("Installs %1$@ with Claude Code.", id), [.run(tool: claude, args: ["plugin", "install", id], cwd: nil)])
                }
                offer(.uninstall, tr("Remove from settings"), tr("Removes %1$@ from enabledPlugins in ~/.claude/settings.json. The file is backed up first.", id),
                      [.removeJSONKey(file: env.url(".claude/settings.json").path, path: ["enabledPlugins", id])])
            }
            if !installedIds.contains(id) {
                add(Finding(.warning, .plugins, agent: "claude", subject: id,
                            tr("enabled in settings but not installed; its skills, hooks and MCP servers are missing"),
                            fix: tr("install it, or remove it from enabledPlugins"), source: "~/.claude/settings.json"))
            }
            if let at = id.lastIndex(of: "@"), !known.isEmpty {
                let market = String(id[id.index(after: at)...])
                if !known.contains(market) {
                    add(Finding(.warning, .plugins, agent: "claude", subject: id,
                                tr("marketplace '%1$@' is not registered, so the plugin can't be updated", market),
                                fix: tr("claude plugin marketplace add <source of %1$@>", market), source: "~/.claude/plugins/known_marketplaces.json"))
                }
            }
        }

        var checkedRoots = Set<String>()
        for (i, p) in installed.enumerated() {
            currentItem = pluginKeys[i]
            offerPlugin(p, enabled: isOn(p.id))
            let scopeNote = p.projectPath.map { " (project \(env.short($0)))" } ?? ""
            if let proj = p.projectPath, !env.exists(proj) {
                add(Finding(.info, .plugins, agent: "claude", subject: p.id + scopeNote,
                            tr("installed for a project directory that no longer exists"),
                            fix: tr("delete its entry from ~/.claude/plugins/installed_plugins.json"), source: env.short(manifest.path)))
                continue
            }
            guard env.exists(p.installPath) else {
                add(Finding(isOn(p.id) ? .error : .warning, .plugins, agent: "claude", subject: p.id + scopeNote,
                            tr("install directory %1$@ is missing; the plugin can't load", env.short(p.installPath)),
                            fix: tr("reinstall it"), source: env.short(manifest.path)))
                continue
            }
            guard isOn(p.id), checkedRoots.insert(p.installPath).inserted else { continue }
            let pluginRoot = URL(fileURLWithPath: p.installPath)
            let pj = pluginRoot.appendingPathComponent(".claude-plugin/plugin.json")
            if env.exists(pj.path), env.json(pj) == nil {
                add(Finding(.error, .plugins, agent: "claude", subject: p.id, tr("plugin.json is not valid JSON"), source: env.short(pj.path)))
            }
            defer { currentItem = nil }
            let hooks = pluginRoot.appendingPathComponent("hooks/hooks.json")
            if env.exists(hooks.path) {
                if let h = env.json(hooks) as? [String: Any] {
                    checkHooks(h["hooks"], agent: "claude", source: hooks, vars: ["CLAUDE_PLUGIN_ROOT": p.installPath])
                } else {
                    add(Finding(.error, .plugins, agent: "claude", subject: p.id, tr("hooks/hooks.json is not valid JSON"), source: env.short(hooks.path)))
                }
            }
            let mcp = pluginRoot.appendingPathComponent(".mcp.json")
            if let m = env.json(mcp) as? [String: Any] {
                let list = Self.jsonServers(m["mcpServers"] ?? m, agent: "claude", source: env.short(mcp.path)).map { s -> MCPServer in
                    var s = s
                    s.command = s.command.map { env.expand($0, vars: ["CLAUDE_PLUGIN_ROOT": p.installPath]) }
                    return s
                }
                servers += list
            }
            skillDirs.append((pluginRoot.appendingPathComponent("skills"), "plugin", "plugin \(p.id)"))
        }
    }

    // MARK: skills

    var skillDirs: [(URL, String, String)] = []

    mutating func checkSkills() {
        let roots: [(URL, String, String)] = [
            (env.url(".claude/skills"), "claude", "~/.claude/skills"),
            (env.url(".agents/skills"), "shared", "~/.agents/skills"),
            (env.url(".codex/skills"), "codex", "~/.codex/skills"),
        ] + skillDirs
        let fm = FileManager.default
        var byName: [String: [(agent: String, real: String, origin: String, key: String)]] = [:]
        for (dir, agent, origin) in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for e in entries.sorted() where !e.hasPrefix(".") {
                let u = dir.appendingPathComponent(e)
                let attrs = try? fm.attributesOfItem(atPath: u.path)
                if attrs?[.type] as? FileAttributeType == .typeSymbolicLink, !fm.fileExists(atPath: u.path) {
                    let target = (try? fm.destinationOfSymbolicLink(atPath: u.path)) ?? "?"
                    item(.skills, agent: agent, id: u.path, name: e, detail: "→ " + target, source: origin)
                    offer(.fix, tr("Remove broken link"), tr("Deletes the symlink %1$@. Its target is already gone.", env.short(u.path)), [.unlink(path: u.path)])
                    add(Finding(.warning, .skills, agent: agent, subject: e,
                                tr("broken symlink → %1$@; the skill no longer loads", target),
                                fix: tr("remove the link"), source: origin))
                    continue
                }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let skill = u.appendingPathComponent("SKILL.md")
                guard let text = try? String(contentsOf: skill, encoding: .utf8) else {
                    // A folder of skills (e.g. a synced collection) is fine; an empty one is not.
                    let nested = Self.containsSkill(u, depth: 3)
                    if !nested {
                        item(.skills, agent: agent, id: u.path, name: e, detail: env.short(u.path), source: origin)
                        if agent != "plugin" { offerSkillRemoval(u) }
                        add(Finding(.warning, .skills, agent: agent, subject: e, tr("directory has no SKILL.md, so it isn't a skill"),
                                    fix: tr("add SKILL.md or remove the folder"), source: origin))
                    }
                    continue
                }
                inventory.skills += 1
                let front = Self.frontMatter(text)
                let key = item(.skills, agent: agent, id: u.path, name: front?["name"] ?? e,
                               detail: front?["description"] ?? env.short(u.path), source: origin)
                if agent != "plugin" { offerSkillRemoval(u) }
                if front == nil || front?["description"]?.isEmpty != false {
                    add(Finding(.warning, .skills, agent: agent, subject: e,
                                tr("SKILL.md has no front matter description, so agents can't tell when to use it"),
                                fix: tr("start SKILL.md with ---\\nname: %1$@\\ndescription: …\\n---", e), source: origin))
                }
                let name = front?["name"] ?? e
                byName[name, default: []].append((agent, u.resolvingSymlinksInPath().path, origin, key))
            }
        }
        // The same name in two folders one agent loads: it uses one and silently ignores the other.
        // Plugin skills are namespaced (plugin:skill), so they can't collide.
        for (name, copies) in byName.sorted(by: { $0.key < $1.key }) {
            // Claude Code reads ~/.claude/skills only; Codex also reads the shared ~/.agents/skills.
            for agent in ["claude", "codex"] {
                let visible = copies.filter { $0.agent == agent || (agent == "codex" && $0.agent == "shared") }
                guard Set(visible.map(\.real)).count > 1 else { continue }
                currentItem = visible[0].key
                add(Finding(.info, .skills, agent: agent, subject: name,
                            tr("%1$@ different skills share this name (%2$@); only one is used", String(visible.count), visible.map(\.origin).joined(separator: ", ")),
                            fix: tr("rename or remove the copy you don't want"), source: nil))
            }
        }
    }

    static func containsSkill(_ dir: URL, depth: Int) -> Bool {
        guard depth > 0, let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return items.contains { item in
            let u = dir.appendingPathComponent(item)
            return FileManager.default.fileExists(atPath: u.appendingPathComponent("SKILL.md").path) || containsSkill(u, depth: depth - 1)
        }
    }

    static func frontMatter(_ text: String) -> [String: String]? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        var out: [String: String] = [:]
        var lastKey: String?
        for l in lines[1..<end] {
            if let c = l.firstIndex(of: ":"), !l.hasPrefix("-"), l.range(of: "^[A-Za-z_-]+:", options: .regularExpression) != nil {
                let k = String(l[..<c])
                out[k] = l[l.index(after: c)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                lastKey = k
            } else if let k = lastKey, out[k] == "|" || out[k] == ">" || out[k] == ">-" || out[k] == "|-" || out[k]?.isEmpty == true {
                out[k] = l  // block scalar: first line is enough to know it's non-empty
            }
        }
        return out
    }

    static func duration(_ s: Double) -> String {
        guard s.isFinite else { return "unknown" }
        let value = s >= 3600 ? s / 3600 : s >= 60 ? s / 60 : s
        let unit = s >= 3600 ? "h" : s >= 60 ? "min" : "s"
        return String(format: "%g", value.rounded(.towardZero)) + " " + unit
    }
}

// MARK: - Actions

extension ConfigChecks {
    /// Attaches an action to the current item.
    mutating func offer(_ kind: ActionKind, _ title: String, _ summary: String, _ steps: [Step], destructive: Bool? = nil, bulk: Bool = true) {
        guard let key = currentItem, let i = items.firstIndex(where: { $0.id == key }) else { return }
        let id = key + "|" + kind.rawValue + "|" + String(items[i].actions.count)
        items[i].actions.append(Action(id: id, kind: kind, title: title, summary: summary, steps: steps,
                                       destructive: destructive ?? (kind == .uninstall), bulk: bulk))
    }

    /// MCP servers are removed through their agent's own CLI where there is one; Claude rewrites
    /// ~/.claude.json constantly, so editing it directly would race with running sessions.
    mutating func offerRemoval(_ s: MCPServer) {
        let file = env.expand(s.source)
        if s.source.contains("/plugins/cache/") { return }  // ships with a plugin
        switch s.agent {
        case "claude":
            if let project = s.project, !env.exists(project) {
                offer(.uninstall, tr("Remove server"),
                      tr("The project folder is gone, so this removes the entry from ~/.claude.json directly. The file is backed up first; Claude Code may rewrite it at the same moment, so close idle sessions first."),
                      [.removeJSONKey(file: file, path: ["projects", project, "mcpServers", s.name])])
            } else if let claude = env.resolve("claude") {
                let step: Step = s.project.map { .run(tool: claude, args: ["mcp", "remove", s.name, "-s", "local"], cwd: $0) }
                    ?? .run(tool: claude, args: ["mcp", "remove", s.name, "-s", "user"], cwd: nil)
                offer(.uninstall, tr("Remove server"), tr("Runs Claude Code's own command to remove %1$@. Sessions already running keep it until they restart.", s.name), [step])
            }
        case "codex":
            if let codex = env.resolve("codex") {
                offer(.uninstall, tr("Remove server"), tr("Runs Codex's own command to remove %1$@ from ~/.codex/config.toml. Sessions already running keep it until they restart.", s.name),
                      [.run(tool: codex, args: ["mcp", "remove", s.name], cwd: nil)])
            }
        default:
            offer(.uninstall, tr("Remove server"), tr("Removes %1$@ from %2$@. The file is backed up first.", s.name, s.source),
                  [.removeJSONKey(file: file, path: ["mcpServers", s.name])])
        }
    }

    mutating func offerPlugin(_ p: InstalledPlugin, enabled: Bool) {
        guard let claude = env.resolve("claude") else { return }
        if let project = p.projectPath, !env.exists(project) { return }  // Claude can't address a project that's gone
        let scope = p.scope == "user" ? "user" : p.scope
        let cwd = p.projectPath
        if !env.exists(p.installPath) {
            offer(.fix, tr("Reinstall"), tr("Installs %1$@ again with Claude Code.", p.id), [.run(tool: claude, args: ["plugin", "install", p.id], cwd: cwd)])
        }
        if enabled {
            offer(.disable, tr("Disable"), tr("Turns %1$@ off without removing it. Its skills, hooks and MCP servers stop loading.", p.id),
                  [.run(tool: claude, args: ["plugin", "disable", p.id, "-s", scope], cwd: cwd)])
        }
        offer(.uninstall, tr("Uninstall"), tr("Runs Claude Code's own command to uninstall %1$@.", p.id),
              [.run(tool: claude, args: ["plugin", "uninstall", p.id, "-s", scope], cwd: cwd)])
    }

    /// A skill that is a symlink loses only the link (the folder may be shared with another agent);
    /// a real folder goes to the Trash.
    mutating func offerSkillRemoval(_ u: URL) {
        let isLink = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.type] as? FileAttributeType == .typeSymbolicLink
        if isLink {
            offer(.uninstall, tr("Remove"), tr("Deletes the link %1$@. The folder it points to is kept.", env.short(u.path)), [.unlink(path: u.path)])
        } else {
            offer(.uninstall, tr("Move to Trash"), tr("Moves %1$@ to the Trash.", env.short(u.path)), [.trash(path: u.path)])
        }
    }
}
