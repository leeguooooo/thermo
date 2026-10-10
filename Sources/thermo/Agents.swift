import AgentDoctor
import Foundation

/// `thermo agents`: what is wrong with the AI agents on this Mac.
struct AgentsCommand {
    let app: App
    var style: Style { app.style }

    func run(_ rest: [String]) throws {
        let sub = rest.first ?? ""
        let name = rest.count > 1 ? rest[1] : nil
        switch sub {
        case "": break
        case "list", "ls": return try list(name)
        case "show": return try show(try required(name, sub))
        case "fix":
            if let name { return try act(on: name, kind: .fix) }
            return try fixAll()
        case "uninstall", "remove", "rm": return try act(on: try required(name, sub), kind: .uninstall)
        case "disable": return try act(on: try required(name, sub), kind: .disable)
        case "run": return try act(on: try required(name, sub), kind: nil)
        default: throw CLIError(Self.usage)
        }
        let report = AgentDoctor.run()
        if app.args.has("json") {
            print(Export.diagnosticJSON(report))
            if report.count(.error) > 0 { exit(1) }
            return
        }
        if app.args.has("csv") {
            print(Export.diagnosticCSV(items: report.items, findings: report.findings, generated: report.generated))
            if report.count(.error) > 0 { exit(1) }
            return
        }
        let all = app.args.has("all")
        let inv = report.inventory
        var lines = [
            style.bold("thermo agents") + style.dim(" · " + (inv.agents.isEmpty ? "no AI agents found" : inv.agents.joined(separator: ", "))),
            style.dim("  \(inv.hooks) hooks · \(inv.mcpServers) MCP servers · \(inv.plugins) plugins · \(inv.skills) skills · "
                      + "\(inv.launchAgents) launch agents · \(report.sessions) Claude sessions"),
            "",
        ]

        let shown = report.findings.filter { all || $0.severity != .info }
        for area in Area.allCases {
            let items = shown.filter { $0.area == area }
            guard !items.isEmpty else { continue }
            lines.append(style.bold(title(area)))
            for f in items {
                let mark = f.severity == .error ? style.red(f.severity.symbol) : f.severity == .warning ? style.yellow(f.severity.symbol) : style.dim(f.severity.symbol)
                let agent = f.agent == "system" ? "" : style.dim(" [\(f.agent)]")
                lines.append("  \(mark) " + style.bold(f.subject) + agent)
                lines.append("    " + f.message)
                if let fix = f.fix { lines.append("    " + style.cyan("→ " + fix)) }
                if all, let src = f.source { lines.append("    " + style.dim(src)) }
            }
            lines.append("")
        }

        let top = report.processes.prefix(all ? 15 : 8)
        if !top.isEmpty {
            lines.append(style.bold("Agent processes") + style.dim("  (by memory)"))
            for g in top {
                let detached = g.detached > 0 ? style.yellow("  \(g.detached) detached") : ""
                lines.append("  " + pad(String(g.count), 4, right: true) + "×  "
                             + pad(String(format: "%.0f MB", g.rssMB), 9, right: true)
                             + pad(String(format: "%.0f%%", g.cpu), 6, right: true) + "  " + g.name + detached)
            }
            lines.append("")
        }

        let hidden = report.count(.info)
        let summary = !report.hasResults ? style.dim(report.headline) : report.count(.error) > 0 ? style.red(report.headline) : report.count(.warning) > 0 ? style.yellow(report.headline) : style.green(report.headline)
        lines.append(summary + (all || hidden == 0 ? "" : style.dim("  (+\(hidden) notes; --all to show)")))
        out(lines)
        if report.count(.error) > 0 { exit(1) }
    }

    /// Everything that was checked, one line each, marked ✓ healthy / · note / ! warning / ✗ error / - off.
    func list(_ filter: String?) throws {
        let areas: [Area]
        if let filter {
            guard let a = Area(rawValue: filter) else {
                throw CLIError("unknown area '\(filter)'; areas: " + Area.allCases.map(\.rawValue).joined(separator: ", "))
            }
            areas = [a]
        } else {
            areas = Area.allCases
        }
        let report = AgentDoctor.run()
        let items = report.items.filter { areas.contains($0.area) }
        if app.args.has("json") { print(Export.diagnosticJSON(items)); return }
        if app.args.has("csv") {
            print(Export.diagnosticCSV(items: items, findings: report.findings.filter { areas.contains($0.area) }, generated: report.generated))
            return
        }
        var lines: [String] = []
        for area in areas {
            let rows = items.filter { $0.area == area }
            guard !rows.isEmpty else { continue }
            let bad = rows.filter { $0.severity == .error || $0.severity == .warning }.count
            lines.append(style.bold(title(area)) + style.dim("  \(rows.count)") + (bad > 0 ? style.yellow("  \(bad) with problems") : style.green("  all OK")))
            for i in rows {
                let mark: String
                switch (i.enabled, i.severity) {
                case (false, _): mark = style.dim("-")
                case (_, .error?): mark = style.red("✗")
                case (_, .warning?): mark = style.yellow("!")
                case (_, .info?): mark = style.dim("·")
                case (_, nil): mark = style.green("✓")
                }
                let agent = i.agent == "system" ? "" : style.dim(" [\(i.agent)]")
                lines.append("  \(mark) " + i.name + agent + "  " + style.dim(String(i.detail.prefix(90))))
                if i.severity == .error || i.severity == .warning {
                    for f in report.findings(for: i) where f.severity != .info { lines.append("      " + f.message) }
                }
            }
            lines.append("")
        }
        out(lines)
    }

    static let usage = """
    usage: thermo agents [--all] [--json]                 what is wrong with the AI agents on this Mac
           thermo agents list [AREA] [--json]             everything checked, marked OK or not
           thermo agents show NAME [--json]               one item: problems, suggestions, numbered actions
           thermo agents fix [--dry-run] [--yes]          every safe automatic fix for problem items
           thermo agents fix|uninstall|disable NAME       that action on one item
           thermo agents run NAME --action N              action N from `show`
      NAME is the item's name or id; narrow with --area AREA and --agent AGENT, or --all for every match.
      Actions print their exact steps first and ask; --yes skips the question, --dry-run only prints.
    """

    func required(_ name: String?, _ sub: String) throws -> String {
        guard let name, !name.isEmpty else { throw CLIError("usage: thermo agents \(sub) NAME (see thermo agents list)") }
        return name
    }

    /// Items called `name` (or with that id), narrowed by --area / --agent.
    func select(_ name: String, in report: DoctorReport) throws -> [AgentItem] {
        var items = report.items.filter { $0.id == name || $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if items.isEmpty {  // also accept a unique prefix such as "codex-computer"
            items = report.items.filter { $0.name.lowercased().hasPrefix(name.lowercased()) }
        }
        if let a = app.args.options["area"] {
            guard let area = Area(rawValue: a) else {
                throw CLIError("unknown area '\(a)'; areas: " + Area.allCases.map(\.rawValue).joined(separator: ", "))
            }
            items = items.filter { $0.area == area }
        }
        if let agent = app.args.options["agent"] { items = items.filter { $0.agent.caseInsensitiveCompare(agent) == .orderedSame } }
        guard !items.isEmpty else { throw CLIError("no item named '\(name)' (see thermo agents list)") }
        return items
    }

    func describe(_ i: AgentItem) -> String {
        "\(i.name)  [\(i.area.rawValue)\(i.agent == "system" ? "" : ", " + i.agent)]" + (i.source.map { "  " + $0 } ?? "")
    }

    /// Everything about one item, with its actions numbered for `run --action N`.
    func show(_ name: String) throws {
        let report = AgentDoctor.run()
        let items = try select(name, in: report)
        if app.args.has("json") {
            struct Shown: Encodable { let item: AgentItem; let findings: [Finding] }
            print(Export.diagnosticJSON(items.map { Shown(item: $0, findings: report.findings(for: $0)) }))
            return
        }
        if app.args.has("csv") {
            let ids = Set(items.map(\.id))
            print(Export.diagnosticCSV(items: items, findings: report.findings.filter { $0.item.map(ids.contains) == true }, generated: report.generated))
            return
        }
        var lines: [String] = []
        for i in items {
            let status = !i.enabled ? style.dim("off") : i.severity == .error ? style.red("error") : i.severity == .warning ? style.yellow("warning")
                : i.severity == .info ? style.dim("note") : style.green("OK")
            lines.append(style.bold(i.name) + "  " + status + style.dim("  \(i.area.rawValue)" + (i.agent == "system" ? "" : " · \(i.agent)")))
            lines.append("  " + i.detail)
            if let src = i.source { lines.append(style.dim("  " + src)) }
            lines.append(style.dim("  id: \(i.id)"))
            for f in report.findings(for: i) {
                lines.append("  " + (f.severity == .error ? style.red("✗ ") : f.severity == .warning ? style.yellow("! ") : style.dim("· ")) + f.message)
                if let fix = f.fix { lines.append("    " + style.cyan("→ " + fix)) }
            }
            if i.actions.isEmpty {
                lines.append(style.dim("  no actions (managed by its plugin or the system)"))
            } else {
                lines.append("  actions:")
                for (n, a) in i.actions.enumerated() {
                    lines.append("    \(n + 1). " + style.bold(a.title) + style.dim("  (\(a.kind.rawValue)\(a.destructive ? ", destructive" : "")\(a.bulk ? "" : ", interrupts something in use"))"))
                    lines.append("       " + a.summary)
                    for st in a.steps { lines.append("       " + style.cyan("$ ") + st.display) }
                }
            }
            lines.append("")
        }
        out(lines)
    }

    /// One action on the item(s) called `name`: the first action of `kind`, or --action N.
    func act(on name: String, kind: ActionKind?) throws {
        let env = DoctorEnvironment()
        let report = AgentDoctor.run(env)
        let items = try select(name, in: report)
        if items.count > 1 && !app.args.has("all") {
            throw CLIError("'\(name)' matches \(items.count) items; narrow with --area/--agent, use the id, or add --all:\n  "
                           + items.map(describe).joined(separator: "\n  "))
        }
        var plans: [(AgentItem, Action)] = []
        for item in items {
            let action: Action?
            if let n = app.args.options["action"] {
                guard let k = Int(n), k >= 1, k <= item.actions.count else {
                    throw CLIError("\(item.name) has \(item.actions.count) action(s); see thermo agents show \"\(item.name)\"")
                }
                action = item.actions[k - 1]
            } else if let kind {
                // A broken item has only a fix that removes it (a dead symlink, a job whose program is gone);
                // for those, uninstalling is that fix.
                action = item.actions.first { $0.kind == kind }
                    ?? (kind == .uninstall ? item.actions.first { a in
                        a.kind == .fix && a.steps.allSatisfy {
                            switch $0 { case .unlink, .trash, .bootout: return true; default: return false }
                        }
                    } : nil)
            } else {
                throw CLIError("usage: thermo agents run NAME --action N (see thermo agents show NAME)")
            }
            guard let action else {
                let available = item.actions.map { $0.kind.rawValue }
                throw CLIError("\(item.name) has no \(kind?.rawValue ?? "such") action"
                               + (available.isEmpty ? " (it is managed by its plugin or the system)" : "; available: " + available.joined(separator: ", ")))
            }
            plans.append((item, action))
        }
        try apply(plans, env: env)
    }

    /// Every bulk-safe automatic fix for items with an error or warning.
    func fixAll() throws {
        let env = DoctorEnvironment()
        let report = AgentDoctor.run(env)
        let plans = report.items.filter { $0.severity == .error || $0.severity == .warning }
            .compactMap { item in item.actions.first { $0.kind == .fix && $0.bulk }.map { (item, $0) } }
        if plans.isEmpty {
            print("nothing to fix automatically" + (report.count(.error) + report.count(.warning) > 0 ? " (see thermo agents for manual fixes)" : ""))
            return
        }
        try apply(plans, env: env)
    }

    /// Shows exactly what will run, asks (unless --yes), runs, then rescans.
    func apply(_ plans: [(AgentItem, Action)], env: DoctorEnvironment) throws {
        var lines = [style.bold(plans.count == 1 ? "1 action" : "\(plans.count) actions")]
        for (item, action) in plans {
            lines.append("  " + style.bold(item.name) + style.dim("  " + action.title) + (action.destructive ? style.yellow("  (destructive)") : ""))
            lines.append("    " + action.summary)
            for s in action.steps { lines.append("    " + style.cyan("$ ") + s.display) }
        }
        out(lines)
        if app.args.has("dry-run") { return }
        if !app.args.has("yes") {
            guard isatty(STDIN_FILENO) != 0 else { throw CLIError("refusing to change anything without --yes when stdin is not a terminal") }
            print("\nGo ahead? Config files are backed up to ~/Library/Application Support/Thermo/Backups first. [y/N] ", terminator: "")
            fflush(stdout)
            guard let answer = readLine(), answer.lowercased().hasPrefix("y") else { print("nothing changed"); return }
        }
        var failed = 0
        for (item, action) in plans {
            let r = ActionRunner.perform(action, env: env)
            if !r.ok { failed += 1 }
            print((r.ok ? style.green("✓ ") : style.red("✗ ")) + item.name + style.dim("  " + action.title))
            for l in r.log where !r.ok { print("    " + l) }
            if let b = r.backups.first { print(style.dim("    backup: " + b)) }
        }
        let after = AgentDoctor.run()
        print("\n" + "after: " + after.headline + style.dim("  (log: ~/Library/Logs/Thermo/fix.log)"))
        if failed > 0 { exit(1) }
    }

    func title(_ c: Area) -> String {
        switch c {
        case .hooks: return "Hooks"
        case .mcp: return "MCP servers"
        case .plugins: return "Plugins"
        case .skills: return "Skills"
        case .statusline: return "Status line"
        case .launchd: return "Launch agents"
        case .processes: return "Processes"
        }
    }
}
