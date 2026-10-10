import AgentDoctor
import AppKit
import SwiftUI

/// Runs the agent doctor off the main thread. A scan spawns ~1 launchctl per launch agent, so it only runs
/// when the tab is opened (and the last result is stale) or on Rescan — never on the sampling timer.
@MainActor
final class AgentScanner: ObservableObject {
    @Published var report: DoctorReport?
    @Published var scanning = false

    func scan(ifOlderThan age: TimeInterval = 0) {
        if scanning { return }
        if let r = report, Date().timeIntervalSince(r.generated) < age { return }
        scanning = true
        Task.detached(priority: .utility) {
            let r = AgentDoctor.run()
            await MainActor.run {
                self.report = r
                self.scanning = false
            }
        }
    }
}

enum AgentFilter: String, CaseIterable, Identifiable {
    case problems = "Problems", all = "All"
    var id: String { rawValue }
}

/// Every hook, MCP server, plugin, skill, launch agent and agent process, grouped by area,
/// each marked healthy / note / warning / error; tap one to see why and how to fix it.
struct AgentsView: View {
    @ObservedObject var scanner: AgentScanner
    /// In the popover the list scrolls in a fixed height; in the report window it fills the window.
    var inWindow = false
    @State var filter: AgentFilter = .problems
    @State var open: Set<Area> = []
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
            if let r = scanner.report { areaStrip(r) }
            HStack {
                Picker("", selection: $filter) {
                    ForEach(AgentFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                Spacer()
                if !inWindow {
                    Button("Open Report") { AgentsWindow.show(scanner) }.controlSize(.small)
                }
            }
            if renderingPreview { list } else if inWindow { ScrollView { list } } else { ScrollView { list }.frame(height: 300) }
        }
        .onAppear { scanner.scan(ifOlderThan: 300) }
    }

    // MARK: header

    var summary: some View {
        HStack(alignment: .firstTextBaseline) {
            if let r = scanner.report {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.headline).font(.callout.bold()).foregroundStyle(color(for: r))
                    Text("\(r.inventory.agents.joined(separator: ", ")) · \(r.sessions) Claude sessions · checked \(r.generated.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Checking AI agents…").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if scanner.scanning { ProgressView().controlSize(.small) }
            Button("Rescan") { scanner.scan() }.disabled(scanner.scanning).controlSize(.small)
        }
    }

    /// One tile per area: how many there are and how many have problems. Tap to jump/open.
    func areaStrip(_ r: DoctorReport) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: inWindow ? 7 : 4)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Area.allCases, id: \.self) { area in
                let items = r.items.filter { $0.area == area }
                let bad = items.filter { $0.severity == .error || $0.severity == .warning }.count
                let worst = items.compactMap(\.severity).min()
                VStack(spacing: 1) {
                    Text("\(items.count)").font(.callout.monospacedDigit().bold())
                    Text(shortTitle(area)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Text(bad == 0 ? "OK" : "\(bad) bad").font(.caption2.bold())
                        .foregroundStyle(bad == 0 ? Color.green : tint(worst))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(bad == 0 ? Color.secondary.opacity(0.08) : tint(worst).opacity(0.12)))
                .contentShape(Rectangle())
                .onTapGesture {
                    if bad == 0 { filter = .all }
                    open.insert(area)
                }
            }
        }
    }

    // MARK: list

    var list: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            if let r = scanner.report {
                let anyProblem = r.items.contains { isProblem($0) } || !r.findings.filter { $0.item == nil && $0.severity != .info }.isEmpty
                if filter == .problems && !anyProblem {
                    Text("No problems: hooks, MCP servers, plugins, skills and launch agents look healthy.")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                ForEach(Area.allCases, id: \.self) { area in section(area, r) }
            }
        }
    }

    func isProblem(_ i: AgentItem) -> Bool { i.severity == .error || i.severity == .warning }

    @ViewBuilder func section(_ area: Area, _ r: DoctorReport) -> some View {
        let all = r.items.filter { $0.area == area }
        let shown = filter == .problems ? all.filter(isProblem) : all
        let general = r.general(area).filter { filter == .all || $0.severity != .info }
        if !shown.isEmpty || !general.isEmpty {
            // Problems are always expanded; the full list opens on demand.
            let isOpen = filter == .problems || open.contains(area)
            let bad = all.filter(isProblem).count
            HStack(spacing: 6) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                Text(title(area)).font(.caption.bold())
                Text("\(all.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if bad > 0 {
                    Text("\(bad) with problems").font(.caption2.bold()).foregroundStyle(tint(all.compactMap(\.severity).min()))
                } else {
                    Text("all OK").font(.caption2).foregroundStyle(.green)
                }
            }
            .padding(.top, 8).padding(.bottom, 2)
            .contentShape(Rectangle())
            .onTapGesture { if open.contains(area) { open.remove(area) } else { open.insert(area) } }

            if isOpen {
                ForEach(Array(general.enumerated()), id: \.offset) { _, f in generalRow(f) }
                ForEach(shown) { item in row(item, r.findings(for: item)) }
            }
        }
    }

    func row(_ item: AgentItem, _ findings: [Finding]) -> some View {
        let isExpanded = expanded.contains(item.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                status(item)
                Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(item.enabled ? .primary : .secondary)
                if item.agent != "system" { Text(item.agent).font(.caption2).foregroundStyle(.tertiary) }
                Spacer()
                if let f = findings.first(where: { $0.severity == item.severity }), !isExpanded {
                    Text(label(f.severity)).font(.caption2).foregroundStyle(tint(f.severity))
                }
            }
            Text(item.detail).font(.caption.monospaced()).foregroundStyle(.tertiary)
                .lineLimit(isExpanded ? 4 : 1).truncationMode(.middle).padding(.leading, 18)
            if isProblem(item) || isExpanded {
                ForEach(Array(findings.enumerated()), id: \.offset) { _, f in
                    if isExpanded || f.severity != .info { finding(f, full: isExpanded) }
                }
            }
            if isExpanded, let src = item.source {
                Text(src).font(.caption2.monospaced()).foregroundStyle(.tertiary).padding(.leading, 18)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(isProblem(item) ? tint(item.severity).opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { if isExpanded { expanded.remove(item.id) } else { expanded.insert(item.id) } }
    }

    func generalRow(_ f: Finding) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon(f.severity)).foregroundStyle(tint(f.severity)).font(.caption).frame(width: 12)
                Text(f.subject).font(.callout)
                if f.agent != "system" { Text(f.agent).font(.caption2).foregroundStyle(.tertiary) }
            }
            finding(f, full: true)
        }
        .padding(.vertical, 4).padding(.horizontal, 4)
    }

    func finding(_ f: Finding, full: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(f.message).font(.caption).foregroundStyle(f.severity == .info ? .secondary : tint(f.severity))
                .lineLimit(full ? nil : 2).fixedSize(horizontal: false, vertical: true)
            if full, let fix = f.fix {
                HStack(alignment: .top, spacing: 4) {
                    Text("Fix:").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(fix).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fix, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy")
                }
            }
        }
        .padding(.leading, 18)
    }

    func status(_ item: AgentItem) -> some View {
        Group {
            if !item.enabled {
                Image(systemName: "minus.circle").foregroundStyle(.tertiary)
            } else if let s = item.severity {
                Image(systemName: icon(s)).foregroundStyle(tint(s))
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .font(.caption).frame(width: 12)
    }

    // MARK: style

    func color(for r: DoctorReport) -> Color {
        r.count(.error) > 0 ? .red : r.count(.warning) > 0 ? .orange : .green
    }

    func icon(_ s: Severity) -> String {
        s == .error ? "xmark.octagon.fill" : s == .warning ? "exclamationmark.triangle.fill" : "info.circle"
    }

    func label(_ s: Severity) -> String { s == .error ? "error" : s == .warning ? "warning" : "note" }

    func tint(_ s: Severity?) -> Color { s == .error ? .red : s == .warning ? .orange : .secondary }

    func title(_ a: Area) -> String {
        switch a {
        case .hooks: return "Hooks"
        case .mcp: return "MCP servers"
        case .plugins: return "Plugins"
        case .skills: return "Skills"
        case .statusline: return "Status line"
        case .launchd: return "Launch agents"
        case .processes: return "Agent processes"
        }
    }

    func shortTitle(_ a: Area) -> String {
        switch a {
        case .statusline: return "Status"
        case .launchd: return "Launchd"
        case .processes: return "Procs"
        case .mcp: return "MCP"
        default: return title(a)
        }
    }
}

/// The full report in a resizable window, sharing the popover's scan.
@MainActor
enum AgentsWindow {
    private static var window: NSWindow?

    static func show(_ scanner: AgentScanner) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "AI Agent Diagnostics"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: AgentsView(scanner: scanner, inWindow: true).padding(16)
                .frame(minWidth: 520, minHeight: 480))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
