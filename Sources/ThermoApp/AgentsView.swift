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
    /// A batch of fixes in progress ("Fixing 3 of 9: …") and, afterwards, what it achieved.
    @Published var batch: Batch?

    struct Batch {
        var total: Int
        var done = 0
        var failed = 0
        var current = ""
        var finished = false
        var before = 0
        var after = 0
    }

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

    /// The safe automatic fix of every problem item: what "Fix all" runs.
    var bulkFixes: [(AgentItem, Action)] {
        problems.compactMap { item in item.actions.first { $0.kind == .fix && $0.bulk }.map { (item, $0) } }
    }

    /// Runs fixes one after another, reporting progress, then rescans and records how many problems are left.
    func performAll(_ plans: [(AgentItem, Action)]) {
        guard batch?.finished != false, running == nil, !plans.isEmpty else { return }
        batch = Batch(total: plans.count, before: problems.count)
        Task.detached(priority: .userInitiated) {
            let env = DoctorEnvironment()
            var failed = 0
            for (i, (item, action)) in plans.enumerated() {
                await MainActor.run { self.batch?.current = item.name; self.batch?.done = i }
                if !ActionRunner.perform(action, env: env).ok { failed += 1 }
            }
            let r = AgentDoctor.run()
            let failures = failed
            await MainActor.run {
                self.report = r
                self.batch?.done = plans.count
                self.batch?.failed = failures
                self.batch?.after = r.items.filter(\.isProblem).count
                self.batch?.finished = true
            }
        }
    }
}

extension AgentItem {
    var isProblem: Bool { severity == .error || severity == .warning }
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
                        AgentsWindow.show(scanner, entry: .area(item.area))
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

/// The diagnostics window, sharing the popover's scan.
@MainActor
enum AgentsWindow {
    private(set) static var window: NSWindow?
    private static let state = WindowState()

    final class WindowState: ObservableObject {
        @Published var entry: SidebarEntry? = .home
    }

    static func show(_ scanner: AgentScanner, entry: SidebarEntry? = nil) {
        if let entry { state.entry = entry }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            // The gradient sidebar runs up under the title bar, like CleanMyMac.
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            // Content first, and let SwiftUI set only the minimum: otherwise the hosting controller shrinks
            // the window to its minimum and the autosaved frame remembers that.
            let host = NSHostingController(rootView: Host(scanner: scanner, state: state)
                .frame(minWidth: 900, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity))
            host.sizingOptions = [.minSize]
            w.contentViewController = host
            if !w.setFrameUsingName("AgentDiagnostics2") || w.frame.width < 960 || w.frame.height < 640 {
                w.setContentSize(NSSize(width: 1080, height: 720))
                w.center()
            }
            w.setFrameAutosaveName("AgentDiagnostics2")
            // Verification screenshots (`--offscreen`) must never appear on the user's screen. macOS pulls
            // titled windows back on screen, so this one is borderless and parked far outside every display.
            if CommandLine.arguments.contains("--offscreen") {
                w.styleMask = [.borderless]
                w.setFrame(NSRect(x: -6000, y: -6000, width: 1080, height: 720), display: true)
            }
            window = w
        }
        window?.title = tr("AI Agent Diagnostics")
        if CommandLine.arguments.contains("--offscreen") {
            window?.orderBack(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    /// Verification: waits for the scan, lets animations settle, writes the window's content as a PNG, quits.
    static func snapshotWhenReady(_ scanner: AgentScanner, to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard scanner.report != nil, !scanner.scanning else { return snapshotWhenReady(scanner, to: path) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    do { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)) }
                    catch { FileHandle.standardError.write("snapshot: \(error)\n".data(using: .utf8)!) }
                } else {
                    FileHandle.standardError.write("snapshot: no window content (window \(String(describing: window)))\n".data(using: .utf8)!)
                }
                exit(0)
            }
        }
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
