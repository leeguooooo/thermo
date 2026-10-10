import AgentDoctor
import Foundation

/// `thermo agents`: what is wrong with the AI agents on this Mac.
struct AgentsCommand {
    let app: App
    var style: Style { app.style }

    func run(_ rest: [String]) throws {
        if rest.first == "list" || rest.first == "ls" { return try list(rest.count > 1 ? rest[1] : nil) }
        guard rest.isEmpty else { throw CLIError("usage: thermo agents [list [AREA]] [--all] [--json]") }
        let report = AgentDoctor.run()
        if app.args.has("json") { print(Export.json(report)); return }
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
        let summary = report.count(.error) > 0 ? style.red(report.headline) : report.count(.warning) > 0 ? style.yellow(report.headline) : style.green(report.headline)
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
        if app.args.has("json") { print(Export.json(items)); return }
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
