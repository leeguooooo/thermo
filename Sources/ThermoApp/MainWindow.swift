import AgentDoctor
import AppKit
import CleanKit
import SwiftUI
import ThermoKit
import ThermoL10n

/// What the app keeps once: the menu bar panel and the main window show the same models.
@MainActor
final class AppModels {
    static let shared = AppModels()
    lazy var monitor = Monitor()
    lazy var updates = Updates()
    lazy var disk = DiskModel()
    lazy var agents = AgentScanner()
    private var browsers: [String: ChromePagesModel] = [:]

    /// One pages model per browser, so its last result is still there when the page is reopened.
    func browser(_ app: String, memoryKB: Int? = nil, gpuKB: Int? = nil) -> ChromePagesModel {
        let m = browsers[app] ?? ChromePagesModel(app: app, appMemoryKB: memoryKB, gpuKB: gpuKB)
        if let memoryKB { m.appMemoryKB = memoryKB }
        if let gpuKB { m.gpuKB = gpuKB }
        browsers[app] = m
        return m
    }
}

/// Where the main window is.
enum MainPage: Hashable {
    case overview, sensors, fans, settings
    case browser(String)
    case disk(DiskPage)
    case agents(SidebarEntry)

    /// `--page` values: overview, sensors, fans, settings, pages, disk, disk:overview, disk:<category>,
    /// agents, agents:<area>.
    init?(argument: String) {
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "overview": self = .overview
        case "sensors": self = .sensors
        case "fans": self = .fans
        case "settings": self = .settings
        case "pages": self = .browser(parts.count > 1 ? parts[1] : "Google Chrome")
        case "disk": self = .disk(parts.count > 1 ? (DiskPage(argument: parts[1]) ?? .home) : .home)
        case "agents": self = .agents(parts.count > 1 ? (Area(rawValue: parts[1]).map { .area($0) } ?? .home) : .home)
        default: return nil
        }
    }

    var isDisk: Bool { if case .disk = self { return true } else { return false } }
    var isAgents: Bool { if case .agents = self { return true } else { return false } }
}

/// The main window: everything Thermo does, in the Disk Cleanup look — a sidebar of places and a
/// page for each. The menu bar panel keeps the live numbers and a few quick controls.
@MainActor
enum MainWindow {
    private(set) static var window: NSWindow?
    static let state = State()

    final class State: ObservableObject {
        @Published var page: MainPage = .overview
    }

    static var offscreen: Bool { CommandLine.arguments.contains("--offscreen") }

    static func show(_ page: MainPage? = nil) {
        if let page { state.page = page }
        let models = AppModels.shared
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            // Content first, SwiftUI sets only the minimum; autosave last (it would record the shrunken size).
            let host = NSHostingController(rootView: Host(state: state, models: models)
                .frame(minWidth: 940, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity))
            host.sizingOptions = [.minSize]
            w.contentViewController = host
            if !w.setFrameUsingName("ThermoMain") || w.frame.width < 960 || w.frame.height < 640 {
                w.setContentSize(NSSize(width: 1100, height: 740))
                w.center()
            }
            w.setFrameAutosaveName("ThermoMain")
            // Verification screenshots never appear on the user's screen.
            if offscreen {
                w.styleMask = [.borderless]
                w.setFrame(NSRect(x: -6000, y: -6000, width: 1100, height: 740), display: true)
            }
            // Live numbers only while the window can be seen.
            let center = NotificationCenter.default
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { models.monitor.windowOpen = w.isVisible && w.occlusionState.contains(.visible) }
            }
            center.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated {
                    models.monitor.windowOpen = false
                    for m in [models.browser("Google Chrome")] where m.running { m.stop() }
                }
            }
            window = w
        }
        window?.title = "Thermo"
        models.monitor.windowOpen = true
        if offscreen {
            window?.orderBack(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    /// Verification: once `ready`, lets animations settle, writes the window as a PNG and quits.
    static func snapshot(to path: String, when ready: @escaping @MainActor () -> Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                guard ready() else { return snapshot(to: path, when: ready) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    exit(0)
                }
            }
        }
    }

    struct Host: View {
        @ObservedObject var state: State
        let models: AppModels
        @AppStorage(L10n.defaultsKey) private var language = "system"
        var body: some View {
            MainView(page: $state.page, monitor: models.monitor, disk: models.disk, agents: models.agents, models: models)
                .id(language)
        }
    }
}

struct MainView: View {
    @Binding var page: MainPage
    @ObservedObject var monitor: Monitor
    @ObservedObject var disk: DiskModel
    @ObservedObject var agents: AgentScanner
    let models: AppModels
    @State private var confirmingClean = false

    var body: some View {
        ZStack {
            WindowBackdrop(glow: glow, tint: tint)
            HStack(spacing: 0) {
                MainSidebar(page: $page, monitor: monitor, disk: disk, agents: agents)
                    .frame(width: 236).background(Color.black.opacity(0.22))
                Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
                ZStack { content }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.25), value: page)
        .onChange(of: page) { p in if p.isAgents { agents.scan(ifOlderThan: 60) } }
        .onAppear {
            if page.isAgents { agents.scan(ifOlderThan: 60) }
            if page.isDisk, disk.report == nil, !disk.scanning { disk.loadSaved() }
        }
        .sheet(isPresented: $confirmingClean) {
            ConfirmSheet(title: tr("Clean %1$@?", ByteFormat.string(disk.selectedBytes)), summary: disk.confirmSummary,
                         destructive: disk.selectedItems.contains { $0.safety == .safe }, heading: tr("What will be removed"),
                         lines: disk.planLines,
                         footnote: tr("Removed items are listed in ~/Library/Logs/Thermo/clean.log. Anything changed since the scan is skipped."),
                         confirmTitle: tr("Clean"),
                         confirm: { confirmingClean = false; disk.clean() }, cancel: { confirmingClean = false })
        }
        .sheet(isPresented: Binding(get: { agents.batch?.finished == true }, set: { if !$0 { agents.batch = nil } })) {
            BatchResult(scanner: agents)
        }
    }

    var glow: Bool {
        switch page {
        case .overview, .disk(.home), .agents(.home): return true
        default: return false
        }
    }

    var tint: Color {
        switch page {
        case .agents:
            guard let r = agents.report else { return Color(red: 0.42, green: 0.36, blue: 1.0) }
            return r.count(.error) > 0 ? .red : r.count(.warning) > 0 ? .orange : .green
        case .disk: return Color(red: 0.36, green: 0.42, blue: 1.0)
        default: return heatColor(monitor.snapshot?.hottest).opacity(0.8)
        }
    }

    func startClean() { if !disk.selectedItems.isEmpty { confirmingClean = true } }

    @ViewBuilder var content: some View {
        switch page {
        case .overview:
            OverviewPage(monitor: monitor, open: { page = $0 }).transition(.opacity)
        case .sensors:
            WindowPage(title: tr("Sensors"), subtitle: monitor.model) {
                SensorsView(monitor: monitor, scrolls: false).padding(18).glass()
            }
        case .fans:
            WindowPage(title: tr("Fans"), subtitle: tr("Choose how fast each fan runs. Settings stay when Thermo quits or updates.")) {
                FansView(monitor: monitor).padding(18).glass()
            }
        case .settings:
            WindowPage(title: tr("Settings"), subtitle: "Thermo \(AppInfo.version)") {
                SettingsView(monitor: monitor, updates: models.updates)
            }
        case let .browser(app):
            ChromePagesView(model: models.browser(app), embedded: true).id(app).transition(.opacity)
        case .disk(.home):
            DiskHome(model: disk, open: { page = .disk(.category($0)) }, clean: startClean).transition(.opacity)
        case .disk(.overview):
            DiskOverviewView().transition(.opacity)
        case let .disk(.category(c)):
            DiskCategoryPage(model: disk, category: c, clean: startClean).id(c)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        case .agents(.home):
            DiagnosticsHome(scanner: agents, open: { a in page = .agents(.area(a)) }).transition(.opacity)
        case let .agents(.area(a)):
            AreaPage(scanner: agents, area: a).id(a).transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }
}

/// A plain page: a big title, a line under it, then its content, scrolling.
struct WindowPage<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.callout).foregroundStyle(.white.opacity(0.6))
                    }
                }
                content()
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 48).padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Sidebar

struct MainSidebar: View {
    @Binding var page: MainPage
    @ObservedObject var monitor: Monitor
    @ObservedObject var disk: DiskModel
    @ObservedObject var agents: AgentScanner
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false

    var items: [CleanItem] { disk.report?.items ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "thermometer.medium").foregroundStyle(.white.opacity(0.85))
                Text("Thermo").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 16).padding(.top, 44).padding(.bottom, 14)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    row(.overview, tr("Overview"), "gauge.with.dots.needle.67percent", .orange,
                        trailing: monitor.snapshot.map { tempText($0.hottest, fahrenheit: fahrenheit) })
                    row(.sensors, tr("Sensors"), "thermometer.medium", .red, trailing: nil)
                    row(.fans, tr("Fans"), "fan.fill", .blue,
                        trailing: monitor.snapshot?.fans.map(\.rpm).max().map { tr("%1$@ rpm", String(Int($0))) })
                    row(.browser("Google Chrome"), tr("Browser pages"), "rectangle.stack.fill", .teal, trailing: nil)

                    header(tr("Disk Cleanup"))
                    row(.disk(.home), tr("Smart Scan"), "sparkles", .pink, trailing: disk.report.map { ByteFormat.string($0.totalBytes) })
                    if page.isDisk {
                        row(.disk(.overview), tr("Where the space is"), "chart.pie.fill", .teal, trailing: nil, indent: true)
                        ForEach(CleanCategory.allCases, id: \.self) { c in
                            let bytes = disk.report?.bytes(in: c) ?? 0
                            if bytes > 0 || items.contains(where: { $0.category == c }) {
                                row(.disk(.category(c)), c.title, DiskStyle.icon(c), DiskStyle.tint(c), trailing: ByteFormat.string(bytes), indent: true)
                            }
                        }
                    }

                    header(tr("AI Agent Diagnostics"))
                    row(.agents(.home), tr("Smart Check"), "stethoscope", .purple, trailing: nil, badge: agents.problems.count)
                    if page.isAgents {
                        ForEach(Area.allCases, id: \.self) { a in
                            row(.agents(.area(a)), AgentStyle.title(a), AgentStyle.icon(a), AgentStyle.tint(a), trailing: nil,
                                badge: agents.report?.items.filter { $0.area == a && $0.isProblem }.count ?? 0, indent: true)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.horizontal, 12)
            row(.settings, tr("Settings"), "gearshape.fill", .gray, trailing: nil).padding(.vertical, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    func header(_ title: String) -> some View {
        // Upper case only reads well in Latin script ("AI AGENT 诊断" does not).
        Text(L10n.current == .english ? title.uppercased() : title).font(.system(size: 10, weight: .semibold)).tracking(0.8)
            .foregroundStyle(.white.opacity(0.4)).padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 6)
    }

    func row(_ target: MainPage, _ title: String, _ symbol: String, _ color: Color, trailing: String?,
             badge: Int = 0, indent: Bool = false) -> some View {
        let on = page == target
        return Button { page = target } label: {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, color: color, size: indent ? 20 : 24)
                Text(title).font(.system(size: 13, weight: on ? .semibold : .regular)).foregroundStyle(.white.opacity(on ? 1 : 0.8))
                    .lineLimit(1)
                Spacer()
                if badge > 0 {
                    Text("\(badge)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(LinearGradient(colors: [.orange, .red.opacity(0.8)], startPoint: .top, endPoint: .bottom)))
                } else if let trailing {
                    Text(trailing).font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, indent ? 5 : 7)
            .padding(.leading, indent ? 12 : 0)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(on ? 0.13 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .padding(.horizontal, 8)
    }
}

// MARK: - Overview

/// The window's front page: four gauges (temperature, CPU load, memory, disk), the live numbers,
/// why the Mac is slow, and the trend.
struct OverviewPage: View {
    @ObservedObject var monitor: Monitor
    let open: (MainPage) -> Void
    @ObservedObject private var pulse = SystemPulse.shared
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false

    var body: some View {
        WindowPage(title: tr("Overview"), subtitle: monitor.model) {
            TimelineView(.periodic(from: .now, by: 3)) { _ in gauges }
            chips
            PulseCard(active: monitor.panelVisible, plain: true).padding(8).glass()
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("Temperature, last 10 minutes")).font(.callout.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                TemperatureChart(history: monitor.history)
            }
            .padding(16).glass()
        }
    }

    var gauges: some View {
        let s = monitor.snapshot
        let hot = s?.hottest
        let load = pulse.current.map { $0.load1 / Double(max(1, $0.cores)) }
        let mem = SystemStats.memory()
        let disk = SystemStats.disk()
        return HStack(spacing: 12) {
            card(tr("Temperature"), RingGauge(value: ((hot ?? 30) - 30) / 80, text: tempText(hot, fahrenheit: fahrenheit),
                                             caption: tr("hottest")),
                 detail: "CPU \(tempText(s?.cpu, fahrenheit: fahrenheit)) · GPU \(tempText(s?.gpu, fahrenheit: fahrenheit))") { open(.sensors) }
            card(tr("CPU load"), RingGauge(value: (load ?? 0) / 2, text: load.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
                                          caption: pulse.current.map { tr("%1$@ cores", String($0.cores)) }),
                 detail: pulse.current.map { tr("load %1$@", String(format: "%.1f", $0.load1)) } ?? "") { open(.overview) }
            card(tr("Memory"), RingGauge(value: mem.map { Double($0.usedBytes) / Double(max(1, $0.totalBytes)) } ?? 0,
                                        text: mem.map { String(format: "%.0f%%", Double($0.usedBytes) / Double(max(1, $0.totalBytes)) * 100) } ?? "—",
                                        caption: MachinePulse.memoryName(pulse.memory)),
                 detail: [mem.map { tr("%1$@ of %2$@", ByteFormat.string(Int64($0.usedBytes)), ByteFormat.string(Int64($0.totalBytes))) },
                          pulse.current.flatMap { $0.swapUsedMB > 0 ? tr("swap %1$@", ByteFormat.string(Int64($0.swapUsedMB) << 20)) : nil }]
                    .compactMap { $0 }.joined(separator: " · ")) { open(.overview) }
            card(tr("Disk"), RingGauge(value: disk.map { 1 - Double($0.freeBytes) / Double(max(1, $0.totalBytes)) } ?? 0,
                                      text: disk.map { ByteFormat.string($0.freeBytes) } ?? "—", caption: tr("free"),
                                      colors: [.cyan, .blue, .purple, .pink]),
                 detail: disk.map { tr("%1$@ in all", ByteFormat.string($0.totalBytes)) } ?? "") { open(.disk(.home)) }
        }
    }

    /// Fans, power and battery as small chips under the gauges.
    @ViewBuilder var chips: some View {
        let s = monitor.snapshot
        HStack(spacing: 10) {
            if let rpm = s?.fans.map(\.rpm).max() {
                chip("fan.fill", .blue, tr("%1$@ rpm", String(Int(rpm))), s?.fans.contains(where: \.manual) == true ? tr("manual") : tr("auto")) { open(.fans) }
            }
            if let w = s?.systemPower { chip("bolt.fill", .yellow, String(format: "%.1f W", w), tr("System")) { open(.sensors) } }
            if let b = s?.battery, let p = b.percent {
                chip(b.charging ? "battery.100.bolt" : "battery.75", p < 20 ? .red : .green, String(format: "%.0f%%", p),
                     b.health.map { tr("health %1$@%%", String(format: "%.0f", $0 * 100)) } ?? tr("Battery")) { open(.sensors) }
            }
            Spacer()
        }
    }

    func card<G: View>(_ title: String, _ gauge: G, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                gauge
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16).padding(.horizontal, 10)
            .glass(radius: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    func chip(_ symbol: String, _ color: Color, _ value: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glass(radius: 20)
        }
        .buttonStyle(PressableStyle())
    }
}
