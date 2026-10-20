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
        case .worktrees: return "arrow.triangle.pull"
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
        ConfirmSheet(title: tr("%1$@ — %2$@", action.title, item.name), summary: action.summary, destructive: action.destructive,
                     heading: tr("What will run"), lines: action.steps.map(\.display),
                     footnote: tr("Config files are copied to ~/Library/Application Support/Thermo/Backups before they change. Each step is logged to ~/Library/Logs/Thermo/fix.log."),
                     confirmTitle: action.title, confirm: confirm, cancel: cancel)
    }
}

/// The same confirmation layout for actions that are not an AgentDoctor `Action` (e.g. disk cleanup):
/// a title, a summary, the exact lines that will run, and a note on how it can be undone.
struct ConfirmSheet: View {
    let title: String
    let summary: String
    let destructive: Bool
    let heading: String
    let lines: [String]
    var retainedLines: [String] = []
    var detailLines: [String] = []
    let footnote: String
    let confirmTitle: String
    var confirmEnabled = true
    let confirm: () -> Void
    let cancel: () -> Void

    func list(_ values: [String]) -> some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, l in
                Text(l).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    var reviewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading).font(.subheadline.weight(.semibold))
            if lines.isEmpty { Text(tr("No items selected")).font(.caption).foregroundStyle(.secondary) }
            else { list(lines) }
            if !retainedLines.isEmpty {
                Text(tr("Kept in place")).font(.subheadline.weight(.semibold))
                list(retainedLines)
            }
            if !detailLines.isEmpty {
                Text(tr("Details")).font(.subheadline.weight(.semibold))
                list(detailLines)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: destructive ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.title2).foregroundStyle(destructive ? Color.orange : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            // ImageRenderer cannot draw scroll views; previews get the plain list.
            if renderingPreview { reviewContent } else { ScrollView { reviewContent }.frame(maxHeight: 220) }
            Text(footnote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(role: destructive ? .destructive : nil, action: confirm) { Text(confirmTitle) }
                    .disabled(!confirmEnabled)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
        // Set the presentation's native appearance too: a dark SwiftUI environment alone
        // can leave the sheet background light while its labels and Cancel button are white.
        .preferredColorScheme(.dark)
    }
}

// MARK: - CleanMyMac-style surfaces (shared by the Agents and Disk windows)

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

/// The whole window's backdrop.
struct GradientSidebarBackground: View {
    var body: some View { WindowBackdrop(glow: false) }
}

/// Graphite, with a faint light at the top in the color of what the page is about (on the
/// overview, how hot the Mac is); the light eases to a new color instead of jumping.
struct WindowBackdrop: View {
    var glow = true
    var tint: Color = Theme.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.canvas, Theme.canvasDeep], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [tint.opacity(glow ? 0.16 : 0.07), .clear],
                           center: UnitPoint(x: 0.62, y: -0.08), startRadius: 0, endRadius: 560)
                .animation(Theme.gentle.unlessReduced(reduceMotion), value: glow)
        }
        .ignoresSafeArea()
    }
}

/// A panel: what cards and rows sit on. One flat surface with a hairline; no shadow.
struct GlassPanel: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var radius: CGFloat = Theme.radius
    var highlighted = false

    private var panelFill: Color {
        if reduceTransparency || contrast == .increased {
            return highlighted ? Color(red: 0.14, green: 0.15, blue: 0.17) : Color(red: 0.11, green: 0.12, blue: 0.14)
        }
        return highlighted ? Theme.surfaceRaised : Theme.surface
    }

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(panelFill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(contrast == .increased ? Color.white.opacity(0.6) : highlighted ? Theme.border.opacity(1.6) : Theme.hairline,
                              lineWidth: contrast == .increased ? 2 : 1))
    }
}

extension View {
    func glass(radius: CGFloat = Theme.radius, highlighted: Bool = false) -> some View {
        modifier(GlassPanel(radius: radius, highlighted: highlighted))
    }
}

/// A rounded tile holding a symbol in its color: the mark of a category.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(color.opacity(0.16))
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(color.opacity(0.22), lineWidth: 1)
            Image(systemName: symbol).font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Presses in slightly and springs back.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// The main call to action on a landing page ("Fix 9", "Check Again").
struct BigRoundButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    var color: Color = Theme.accent
    var busy = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                }
            }
            .padding(.horizontal, 28).frame(minWidth: 148).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(hover ? 1 : 0.9)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.18)))
            .shadow(color: color.opacity(hover ? 0.45 : 0.25), radius: hover ? 14 : 8, y: 4)
            .animation(Theme.quick.unlessReduced(reduceMotion), value: hover)
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .disabled(busy)
    }
}

/// Buttons in the window. `prominent` fills with the color, for the one thing a page asks you to do;
/// the rest are quiet grey.
struct PillButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    var prominent = false
    var color: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        let small = controlSize == .small || controlSize == .mini
        return PillBody(configuration: configuration, prominent: prominent, color: color, small: small,
                        enabled: isEnabled, reduceMotion: reduceMotion)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let prominent: Bool
        let color: Color
        let small: Bool
        let enabled: Bool
        let reduceMotion: Bool
        @State private var hover = false

        var fill: Color {
            if prominent { return color.opacity(configuration.isPressed ? 0.75 : hover ? 1 : 0.88) }
            return Color.white.opacity(configuration.isPressed ? 0.15 : hover ? 0.11 : 0.075)
        }

        var body: some View {
            configuration.label
                .font(.system(size: small ? 11.5 : 12.5, weight: prominent ? .semibold : .medium))
                .foregroundStyle(prominent ? Color.white : Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, small ? 9 : 12).frame(minHeight: small ? 22 : 28)
                .background(RoundedRectangle(cornerRadius: small ? 6 : 7, style: .continuous).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: small ? 6 : 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(prominent ? 0.16 : 0.08)))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hover = enabled && $0 }
                .animation(reduceMotion ? nil : Theme.quick, value: hover)
                .animation(reduceMotion ? nil : Theme.quick, value: configuration.isPressed)
        }
    }
}

/// The landing hero: a status mark in a ring; the ring turns into progress while working.
struct HeroStatus: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String
    /// 0…1 while scanning or fixing; nil when idle.
    var progress: Double? = nil
    var spinning = false
    @State private var turning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(RadialGradient(colors: [color.opacity(0.22), .clear], center: .center, startRadius: 20, endRadius: 90))
                    .frame(width: 180, height: 180)
                Circle().stroke(Color.white.opacity(0.07), lineWidth: 5).frame(width: 128, height: 128)
                if let progress {
                    Circle().trim(from: 0, to: max(0.02, progress))
                        .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: 128, height: 128)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: progress)
                } else if spinning {
                    Circle().trim(from: 0, to: 0.22)
                        .stroke(AngularGradient(colors: [color.opacity(0), color], center: .center),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .frame(width: 128, height: 128)
                        .rotationEffect(.degrees(turning ? 360 : 0))
                        .animation(reduceMotion ? nil : .linear(duration: 1.1).repeatForever(autoreverses: false), value: turning)
                } else {
                    Circle().stroke(color.opacity(0.85), lineWidth: 5).frame(width: 128, height: 128)
                }
                Image(systemName: symbol).font(.system(size: 40, weight: .semibold)).foregroundStyle(color)
                    .contentTransition(.opacity)
            }
            // Animate only the ring: a repeatForever started with withAnimation in onAppear would also
            // animate the first layout of the whole window, and everything would drift forever.
            .onAppear { DispatchQueue.main.async { turning = true } }
            .animation(Theme.standard.unlessReduced(reduceMotion), value: symbol)
            Text(title).font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center).contentTransition(.numericText())
            Text(subtitle).font(.system(size: 13.5)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                .frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A card for one category on a landing page.
struct CategoryCard: View {
    let symbol: String
    let color: Color
    let title: String
    let status: String
    let statusColor: Color
    /// The big figure on the card ("4"); nil shows a check.
    var count: Int? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    IconTile(symbol: symbol, color: color, size: 32)
                    Spacer()
                    if let count, count > 0 {
                        Text("\(count)").font(Theme.figure(22)).foregroundStyle(statusColor)
                            .contentTransition(.numericText())
                    } else {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.good)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(status).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(14)
            .glass(highlighted: hover)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textTertiary)
                    .padding(14).padding(.top, 58).opacity(hover ? 1 : 0)
            }
            .animation(Theme.quick, value: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
    }
}

/// A glowing ring gauge, as on a car dashboard: the arc fills with the value and runs from green to red.
struct RingGauge: View {
    /// 0…1.
    let value: Double?
    let text: String
    var caption: String? = nil
    var size: CGFloat = 112
    var colors: [Color] = [.green, .yellow, .orange, .red]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var normalizedValue: Double? {
        guard let value, value.isFinite else { return nil }
        return min(1, max(0, value))
    }
    var displayText: String { normalizedValue == nil ? "—" : text }

    var color: Color {
        guard !colors.isEmpty, let normalized = normalizedValue else { return .secondary }
        let i = min(colors.count - 1, Int(normalized * Double(colors.count)))
        return colors[i]
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round))
                .rotationEffect(.degrees(135)).mask(Circle().trim(from: 0, to: 0.75).stroke(lineWidth: size * 0.1).rotationEffect(.degrees(135)))
            if let normalized = normalizedValue, !colors.isEmpty {
                Circle().trim(from: 0, to: 0.75 * normalized)
                    .stroke(AngularGradient(colors: colors, center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .shadow(color: color.opacity(0.35), radius: 4)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: value)
            }
            VStack(spacing: 0) {
                Text(displayText).font(Theme.figure(size * 0.21)).contentTransition(.numericText())
                    .foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.5)
                if let caption {
                    Text(caption).font(.system(size: size * 0.095, weight: .medium)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
            }
            .padding(.horizontal, size * 0.16)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption ?? "")
        .accessibilityValue(normalizedValue == nil ? tr("No reading available") : text)
    }
}
