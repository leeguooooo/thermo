import AgentDoctor
import AppKit
import SwiftUI
import ThermoL10n

// MARK: - Model

/// Runs the agent doctor and its actions off the main thread. A scan spawns ~1 launchctl per launch agent,
/// so it runs when the tab or window opens (if the last result is stale), on Rescan, and after an action.
@MainActor
final class AgentScanner: ObservableObject {
    @Published var report: DoctorReport?
    @Published var scanning = false
    /// The item the diagnostics window shows.
    @Published var selection: AgentItem.ID?
    /// Result of the last action, shown on the item it ran on.
    @Published var lastResult: LastResult?
    @Published var running: Action.ID?

    struct LastResult {
        var item: AgentItem.ID
        var action: String
        var result: ActionResult
    }

    func scan(ifOlderThan age: TimeInterval = 0) {
        if scanning { return }
        if let r = report, Date().timeIntervalSince(r.generated) < age { return }
        scanning = true
        Task.detached(priority: .userInitiated) {
            let r = AgentDoctor.run()
            await MainActor.run {
                self.report = r
                self.scanning = false
            }
        }
    }

    func perform(_ action: Action, on item: AgentItem) {
        guard running == nil else { return }
        running = action.id
        Task.detached(priority: .userInitiated) {
            let result = ActionRunner.perform(action, env: DoctorEnvironment())
            let r = AgentDoctor.run()
            await MainActor.run {
                self.lastResult = LastResult(item: item.id, action: action.title, result: result)
                self.report = r
                self.running = nil
            }
        }
    }

    var problems: [AgentItem] { report?.items.filter(\.isProblem) ?? [] }
}

extension AgentItem {
    var isProblem: Bool { severity == .error || severity == .warning }
}

// MARK: - Shared look

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

// MARK: - Popover tab

/// The popover shows health at a glance; the work happens in the diagnostics window.
struct AgentsView: View {
    @ObservedObject var scanner: AgentScanner

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let r = scanner.report {
                areaGrid(r)
                problemList(r)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.frame(height: 120)
            }
            HStack {
                Button(tr("Rescan")) { scanner.scan() }.disabled(scanner.scanning)
                Spacer()
                Button(tr("Open Diagnostics…")) { AgentsWindow.show(scanner) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .onAppear { scanner.scan(ifOlderThan: 300) }
    }

    var header: some View {
        let r = scanner.report
        let worst = r?.items.compactMap(\.severity).filter { $0 != .info }.min()
        return HStack(spacing: 10) {
            Image(systemName: r == nil ? "stethoscope" : worst == nil ? "checkmark.seal.fill" : AgentStyle.symbol(worst))
                .font(.title2).foregroundStyle(r == nil ? Color.secondary : worst == nil ? .green : AgentStyle.color(worst))
            VStack(alignment: .leading, spacing: 1) {
                Text(r.map { $0.headline } ?? tr("Checking AI agents…")).font(.headline)
                Text(r.map { tr("%1$@ items checked · %2$@ Claude sessions", String($0.items.count), String($0.sessions)) } ?? " ")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if scanner.scanning { ProgressView().controlSize(.small) }
        }
    }

    func areaGrid(_ r: DoctorReport) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(Area.allCases, id: \.self) { area in
                let items = r.items.filter { $0.area == area }
                let bad = items.filter(\.isProblem)
                let worst = bad.compactMap(\.severity).min()
                Button {
                    scanner.selection = bad.first?.id
                    AgentsWindow.show(scanner, entry: .area(area))
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: AgentStyle.icon(area)).foregroundStyle(bad.isEmpty ? Color.secondary : AgentStyle.color(worst))
                        Text(AgentStyle.title(area)).font(.caption2).lineLimit(1).minimumScaleFactor(0.75)
                        Text(bad.isEmpty ? "\(items.count)" : tr("%1$@ issues", String(bad.count)))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(bad.isEmpty ? Color.secondary : AgentStyle.color(worst))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder func problemList(_ r: DoctorReport) -> some View {
        let problems = Array(scanner.problems.prefix(5))
        if problems.isEmpty {
            Label(tr("Hooks, MCP servers, plugins, skills and launch agents look healthy."), systemImage: "checkmark.circle")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(problems) { item in
                    Button {
                        scanner.selection = item.id
                        AgentsWindow.show(scanner, entry: .problems)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            StatusIcon(item: item)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.callout).lineLimit(1).truncationMode(.middle)
                                Text(r.findings(for: item).first?.message ?? item.detail)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 5).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if item.id != problems.last?.id { Divider() }
                }
                if scanner.problems.count > problems.count {
                    Text(tr("and %1$@ more", String(scanner.problems.count - problems.count)))
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
            }
        }
    }
}

// MARK: - Diagnostics window

enum SidebarEntry: Hashable {
    case problems
    case area(Area)
}

/// Sidebar of areas, list of items, and the selected item's problems and actions.
struct DiagnosticsView: View {
    @ObservedObject var scanner: AgentScanner
    @Binding var sidebar: SidebarEntry?
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebar) {
                Section {
                    row(.problems, title: tr("All Problems"), icon: "exclamationmark.triangle", count: scanner.problems.count, bad: true)
                }
                Section(tr("Checks")) {
                    ForEach(Area.allCases, id: \.self) { area in
                        let items = scanner.report?.items.filter { $0.area == area } ?? []
                        let bad = items.filter(\.isProblem).count
                        row(.area(area), title: AgentStyle.title(area), icon: AgentStyle.icon(area),
                            count: bad > 0 ? bad : items.count, bad: bad > 0)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } content: {
            ItemList(scanner: scanner, entry: sidebar ?? .problems, search: search)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            if let id = scanner.selection, let item = scanner.report?.items.first(where: { $0.id == id }) {
                ItemDetail(scanner: scanner, item: item)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "stethoscope").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(tr("Select an item to see what's wrong and how to fix it.")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: Text(tr("Search")))
        .toolbar {
            ToolbarItem(placement: .status) {
                if scanner.scanning {
                    ProgressView().controlSize(.small)
                } else if let r = scanner.report {
                    Text(r.headline).font(.callout)
                        .foregroundStyle(r.count(.error) > 0 ? Color.red : r.count(.warning) > 0 ? Color.orange : Color.green)
                }
            }
            ToolbarItem {
                Button { scanner.scan() } label: { Label(tr("Rescan"), systemImage: "arrow.clockwise") }
                    .disabled(scanner.scanning).help(tr("Rescan"))
            }
        }
        .onAppear { scanner.scan(ifOlderThan: 60) }
    }

    func row(_ entry: SidebarEntry, title: String, icon: String, count: Int, bad: Bool) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if count > 0 {
                    Text("\(count)").font(.caption.monospacedDigit().weight(bad ? .semibold : .regular))
                        .foregroundStyle(bad ? Color.white : Color.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(bad ? Color.orange : Color.clear))
                }
            }
        } icon: {
            Image(systemName: icon)
        }
        .tag(entry)
    }
}

struct ItemList: View {
    @ObservedObject var scanner: AgentScanner
    let entry: SidebarEntry
    let search: String

    var items: [AgentItem] {
        guard let r = scanner.report else { return [] }
        var list: [AgentItem]
        switch entry {
        case .problems: list = r.items.filter(\.isProblem)
        case let .area(a): list = r.items.filter { $0.area == a }
        }
        if !search.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search)
                || $0.agent.localizedCaseInsensitiveContains(search) }
        }
        return list
    }

    var body: some View {
        let items = self.items
        Group {
            if scanner.report == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal").font(.largeTitle).foregroundStyle(.green)
                    Text(search.isEmpty ? tr("Nothing wrong here.") : tr("No matches.")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $scanner.selection) {
                    if case .problems = entry {
                        ForEach(Area.allCases, id: \.self) { area in
                            let group = items.filter { $0.area == area }
                            if !group.isEmpty {
                                Section(AgentStyle.title(area)) { ForEach(group) { ItemRow(item: $0).tag($0.id) } }
                            }
                        }
                    } else {
                        let attention = items.filter { $0.severity != nil && $0.enabled }
                        let rest = items.filter { $0.severity == nil || !$0.enabled }
                        if !attention.isEmpty {
                            Section(tr("Needs attention")) { ForEach(attention) { ItemRow(item: $0).tag($0.id) } }
                        }
                        if !rest.isEmpty {
                            Section(tr("OK")) { ForEach(rest) { ItemRow(item: $0).tag($0.id) } }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
    }

    var title: String {
        switch entry {
        case .problems: return tr("All Problems")
        case let .area(a): return AgentStyle.title(a)
        }
    }
}

struct ItemRow: View {
    let item: AgentItem
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusIcon(item: item)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(item.enabled ? .primary : .secondary)
                    if item.agent != "system" { AgentTag(agent: item.agent) }
                    if !item.enabled { Text(tr("off")).font(.caption2).foregroundStyle(.tertiary) }
                }
                Text(item.detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ItemDetail: View {
    @ObservedObject var scanner: AgentScanner
    let item: AgentItem
    @State private var confirming: Action?

    var findings: [Finding] { scanner.report?.findings(for: item) ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                GroupBox {
                    Text(item.detail).font(.callout.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !findings.isEmpty { problems }
                if let last = scanner.lastResult, last.item == item.id { result(last.action, last.result) }
                if !item.actions.isEmpty { actions }
                if let src = item.source { source(src) }
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .sheet(item: $confirming) { action in
            ConfirmAction(action: action, item: item) {
                confirming = nil
                scanner.perform(action, on: item)
            } cancel: {
                confirming = nil
            }
        }
    }

    var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: AgentStyle.icon(item.area)).font(.title).foregroundStyle(.secondary).frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                HStack(spacing: 6) {
                    StatusIcon(item: item)
                    Text(item.enabled ? AgentStyle.label(item.severity) : tr("Off")).font(.callout).foregroundStyle(.secondary)
                    if item.agent != "system" { AgentTag(agent: item.agent) }
                    Text(AgentStyle.title(item.area)).font(.callout).foregroundStyle(.tertiary)
                }
            }
        }
    }

    var problems: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Problems")).font(.headline)
            ForEach(Array(findings.enumerated()), id: \.offset) { _, f in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: AgentStyle.symbol(f.severity)).foregroundStyle(AgentStyle.color(f.severity))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(f.message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if let fix = f.fix {
                            Text(tr("Suggestion: %1$@", fix)).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Actions")).font(.headline)
            HStack(spacing: 8) {
                ForEach(item.actions) { a in
                    Button(role: a.kind == .uninstall ? .destructive : nil) { confirming = a } label: {
                        HStack(spacing: 4) {
                            if scanner.running == a.id { ProgressView().controlSize(.small) }
                            Text(a.title)
                        }
                    }
                    .modifier(ActionButtonStyle(prominent: a.kind == .fix))
                    .disabled(scanner.running != nil)
                }
            }
            Text(tr("You'll see exactly what will run before anything changes. Config files are backed up first; files go to the Trash."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    func result(_ title: String, _ r: ActionResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(r.ok ? tr("%1$@: done", title) : tr("%1$@: failed", title),
                  systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(r.ok ? .green : .red).font(.callout.weight(.medium))
            ForEach(r.log, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
            if let b = r.backups.first {
                Button(tr("Show backup")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: b)]) }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill((r.ok ? Color.green : Color.red).opacity(0.08)))
    }

    func source(_ src: String) -> some View {
        let path = (src as NSString).expandingTildeInPath
        return HStack {
            Text(tr("Source")).font(.caption).foregroundStyle(.secondary)
            Text(src).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer()
            if FileManager.default.fileExists(atPath: path) {
                Button(tr("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }
}

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

/// The diagnostics window, sharing the popover's scan.
@MainActor
enum AgentsWindow {
    private static var window: NSWindow?
    private static let state = WindowState()

    final class WindowState: ObservableObject {
        @Published var entry: SidebarEntry? = .problems
    }

    static func show(_ scanner: AgentScanner, entry: SidebarEntry? = nil) {
        if let entry { state.entry = entry }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("AgentDiagnostics")
            w.contentViewController = NSHostingController(rootView: Host(scanner: scanner, state: state)
                .frame(minWidth: 860, minHeight: 520))
            if !w.setFrameUsingName("AgentDiagnostics") { w.center() }
            window = w
        }
        window?.title = tr("AI Agent Diagnostics")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    struct Host: View {
        @ObservedObject var scanner: AgentScanner
        @ObservedObject var state: WindowState
        @AppStorage(L10n.defaultsKey) private var language = "system"

        var body: some View {
            DiagnosticsView(scanner: scanner, sidebar: $state.entry).id(language)
        }
    }
}
