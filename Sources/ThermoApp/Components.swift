import AgentDoctor
import SwiftUI
import ThermoL10n

// Components shared by the Agents and Disk views.

// MARK: - Look

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
        }
    }

    static func title(_ area: Area) -> String {
        switch area {
        case .hooks: return tr("Hooks")
        case .mcp: return tr("MCP Servers")
        case .plugins: return tr("Plugins")
        case .skills: return tr("Skills")
        case .statusline: return tr("Status Line")
        case .launchd: return tr("Launch Agents")
        case .processes: return tr("Agent Processes")
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

/// Status glyph for an item: healthy, note, warning, error or switched off.
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

/// Small capsule naming the agent a config belongs to.
struct AgentTag: View {
    let agent: String
    var body: some View {
        Text(agent).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
    }
}

// MARK: - Actions

struct ActionButtonStyle: ViewModifier {
    let prominent: Bool
    func body(content: Content) -> some View {
        if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}

/// Shows every step an action will take before running it.
struct ConfirmAction: View {
    let action: Action
    let item: AgentItem
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: action.destructive ? "exclamationmark.triangle.fill" : "wrench.and.screwdriver.fill")
                    .font(.title2).foregroundStyle(action.destructive ? Color.orange : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("%1$@ — %2$@", action.title, item.name)).font(.headline)
                    Text(action.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(tr("What will run")).font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(action.steps.enumerated()), id: \.offset) { _, s in
                    Text(s.display).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            Text(tr("Config files are copied to ~/Library/Application Support/Thermo/Backups before they change. Each step is logged to ~/Library/Logs/Thermo/fix.log."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(role: action.destructive ? .destructive : nil, action: confirm) { Text(action.title) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
