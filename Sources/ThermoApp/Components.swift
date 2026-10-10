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
    let footnote: String
    let confirmTitle: String
    let confirm: () -> Void
    let cancel: () -> Void

    var list: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                Text(l).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
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
            Text(heading).font(.subheadline.weight(.semibold))
            // ImageRenderer cannot draw scroll views; previews get the plain list.
            if renderingPreview { list } else { ScrollView { list }.frame(maxHeight: 220) }
            Text(footnote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(role: destructive ? .destructive : nil, action: confirm) { Text(confirmTitle) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
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
        }
    }
}

/// The whole window's backdrop: a deep violet-to-blue gradient with soft light, like CleanMyMac.
struct GradientSidebarBackground: View {
    var body: some View { WindowBackdrop(glow: false) }
}

struct WindowBackdrop: View {
    /// A soft light behind the hero.
    var glow = true
    var tint: Color = Color(red: 0.42, green: 0.36, blue: 1.0)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.10, blue: 0.30), Color(red: 0.07, green: 0.10, blue: 0.24),
                                    Color(red: 0.04, green: 0.13, blue: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if glow {
                RadialGradient(colors: [tint.opacity(0.35), .clear], center: UnitPoint(x: 0.5, y: 0.22), startRadius: 10, endRadius: 420)
                    .blendMode(.screen)
            }
        }
        .ignoresSafeArea()
    }
}

/// A translucent "glass" panel: what cards and rows sit on.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = 16
    var highlighted = false

    func body(content: Content) -> some View {
        content
            // Drawn, not a system material: the same frosted look on any backdrop and in snapshots.
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(highlighted ? 0.16 : 0.11), .white.opacity(highlighted ? 0.08 : 0.045)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(highlighted ? 0.35 : 0.18), .white.opacity(0.03)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
    }
}

extension View {
    func glass(radius: CGFloat = 16, highlighted: Bool = false) -> some View { modifier(GlassPanel(radius: radius, highlighted: highlighted)) }
}

/// A rounded tile with a glossy gradient and a white symbol, like an app icon.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(1.0), color.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.8)
            Image(systemName: symbol).font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(0.45), radius: size * 0.18, y: size * 0.08)
    }
}

/// Presses in slightly and springs back.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// The big round call to action ("Fix 9", "Check Again"), glowing.
struct BigRoundButton: View {
    let title: String
    var color: Color = Color(red: 0.25, green: 0.55, blue: 1.0)
    var busy = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color.opacity(0.18)).frame(width: 150, height: 150).blur(radius: hover ? 6 : 10)
                Circle().fill(LinearGradient(colors: [color.opacity(1), color.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 118, height: 118)
                Circle().fill(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center))
                    .frame(width: 118, height: 118)
                Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1.5).frame(width: 118, height: 118)
                if busy {
                    ProgressView().controlSize(.large).tint(.white)
                } else {
                    Text(title).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .multilineTextAlignment(.center).frame(width: 100)
                }
            }
            .shadow(color: color.opacity(hover ? 0.7 : 0.45), radius: hover ? 26 : 18, y: 8)
            .scaleEffect(hover ? 1.03 : 1)
            .animation(.easeOut(duration: 0.18), value: hover)
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .disabled(busy)
    }
}

/// A slim gradient pill for secondary actions on dark glass.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var color: Color = Color(red: 0.25, green: 0.55, blue: 1.0)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(prominent ? AnyShapeStyle(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                                                 : AnyShapeStyle(Color.white.opacity(0.12))))
            .overlay(Capsule().strokeBorder(.white.opacity(prominent ? 0.35 : 0.15)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// The landing hero: a glowing orb in rings; the outer ring turns into progress while working.
struct HeroStatus: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String
    /// 0…1 while scanning or fixing; nil when idle.
    var progress: Double? = nil
    var spinning = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                // Animate only this halo: a repeatForever started with withAnimation in onAppear would also
                // animate the first layout of the whole window, and everything would drift forever.
                Circle().fill(color.opacity(0.10)).frame(width: 190, height: 190).scaleEffect(pulse ? 1.06 : 0.96)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 2.4).repeatForever(), value: pulse)
                Circle().stroke(color.opacity(0.25), lineWidth: 1).frame(width: 162, height: 162)
                if let progress {
                    Circle().trim(from: 0, to: max(0.02, progress))
                        .stroke(AngularGradient(colors: [color.opacity(0.2), color, .white], center: .center),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: 162, height: 162)
                        .animation(.easeInOut(duration: 0.4), value: progress)
                } else if spinning {
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(AngularGradient(colors: [color.opacity(0), color, .white], center: .center),
                                style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: 162, height: 162)
                        .rotationEffect(.degrees(pulse ? 360 : 0))
                        .animation(reduceMotion ? nil : .linear(duration: 1.2).repeatForever(autoreverses: false), value: pulse)
                }
                Circle().fill(LinearGradient(colors: [color, color.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 118, height: 118)
                    .shadow(color: color.opacity(0.6), radius: 24)
                Circle().fill(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center))
                    .frame(width: 118, height: 118)
                Image(systemName: symbol).font(.system(size: 50, weight: .bold)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            }
            .onAppear { DispatchQueue.main.async { pulse = true } }
            Text(title).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .multilineTextAlignment(.center).contentTransition(.numericText())
            Text(subtitle).font(.system(size: 15)).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
                .frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A glass card for one category on the landing page.
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
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    IconTile(symbol: symbol, color: color, size: 42)
                    Spacer()
                    if let count, count > 0 {
                        Text("\(count)").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(statusColor)
                    } else {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.green.opacity(0.85))
                    }
                }
                Spacer(minLength: 0)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text(status).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .padding(16)
            .glass(highlighted: hover)
            .scaleEffect(hover ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
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
            Circle().fill(color.opacity(0.12)).blur(radius: 18)
            Circle().stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round))
                .rotationEffect(.degrees(135)).mask(Circle().trim(from: 0, to: 0.75).stroke(lineWidth: size * 0.1).rotationEffect(.degrees(135)))
            if let normalized = normalizedValue, !colors.isEmpty {
                Circle().trim(from: 0, to: 0.75 * normalized)
                    .stroke(AngularGradient(colors: colors, center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .shadow(color: color.opacity(0.7), radius: 8)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: value)
            }
            VStack(spacing: 0) {
                Text(displayText).font(.system(size: size * 0.22, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.5)
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
