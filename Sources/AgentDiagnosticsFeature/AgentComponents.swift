import ThermoUI
import AgentDoctor
import SwiftUI
import ThermoL10n

enum AgentStyle {
    static func icon(_ area: Area) -> String {
        switch area {
        case .hooks: return "arrow.triangle.branch"
        case .mcp: return "server.rack"
        case .plugins: return "puzzlepiece.extension"
        case .skills: return "book.closed"
        case .statusline: return "menubar.rectangle"
        case .launchd: return "gearshape.2"
        case .processes: return "cpu"
        case .worktrees: return "arrow.triangle.pull"
        }
    }

    static func title(_ area: Area) -> String {
        switch area {
        case .hooks: return tr("Hooks")
        case .mcp: return tr("MCP servers")
        case .plugins: return tr("Plugins")
        case .skills: return tr("Skills")
        case .statusline: return tr("Status line")
        case .launchd: return tr("Launch agents")
        case .processes: return tr("Agent processes")
        case .worktrees: return tr("Worktrees")
        }
    }

    static func color(_ s: Severity?) -> Color {
        switch s {
        case .error?: return .red
        case .warning?: return .orange
        default: return .secondary
        }
    }

    static func symbol(_ s: Severity?) -> String {
        switch s {
        case .error?: return "xmark.octagon.fill"
        case .warning?: return "exclamationmark.triangle.fill"
        case .info?: return "info.circle"
        case nil: return "checkmark.circle.fill"
        }
    }

    static func label(_ s: Severity?) -> String {
        switch s {
        case .error?: return tr("Error")
        case .warning?: return tr("Warning")
        case .info?: return tr("Note")
        case nil: return tr("OK")
        }
    }
}

struct StatusIcon: View {
    let item: AgentItem
    var body: some View {
        Group {
            if !item.enabled {
                Image(systemName: "minus.circle").foregroundStyle(.tertiary)
            } else if item.severity == nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: AgentStyle.symbol(item.severity)).foregroundStyle(AgentStyle.color(item.severity))
            }
        }
        .imageScale(.medium)
    }
}

struct AgentTag: View {
    let agent: String
    var body: some View {
        Text(agent).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
    }
}

struct ConfirmAction: View {
    let action: Action
    let item: AgentItem
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        ConfirmSheet(title: tr("%1$@ — %2$@", action.title, item.name), summary: action.summary, destructive: action.destructive,
                     heading: tr("What will run"), lines: action.steps.map(\.display),
                     footnote: tr("Config files are copied to ~/Library/Application Support/Thermo/Backups before they change. Each step is logged to ~/Library/Logs/Thermo/fix.log."),
                     confirmTitle: action.title, confirm: confirm, cancel: cancel)
    }
}

extension AgentStyle {
    /// One color per area, used for its icon tile and accents.
    static func tint(_ area: Area) -> Color {
        switch area {
        case .hooks: return .purple
        case .mcp: return .blue
        case .plugins: return .orange
        case .skills: return .teal
        case .statusline: return .indigo
        case .launchd: return .pink
        case .processes: return .green
        case .worktrees: return .brown
        }
    }

    /// What the area is, in a sentence a non-developer can follow.
    static func explanation(_ area: Area) -> String {
        switch area {
        case .hooks: return tr("Commands your AI agents run automatically before or after each step.")
        case .mcp: return tr("Tools your AI agents connect to, such as browsers, databases and design apps.")
        case .plugins: return tr("Add-ons installed into Claude Code that bring skills, hooks and tools.")
        case .skills: return tr("Instructions your agents can load when a task needs them.")
        case .statusline: return tr("The line at the bottom of Claude Code that shows usage and status.")
        case .launchd: return tr("Programs macOS starts in the background for your tools.")
        case .processes: return tr("Helper programs your agents start; leftovers keep using memory.")
        case .worktrees: return tr("Extra checkouts agents make for each task; leftovers take disk space.")
        }
    }
}
