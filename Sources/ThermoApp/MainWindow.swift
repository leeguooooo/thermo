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
    lazy var apps = AppsModel()
    lazy var claudeCleanup = ClaudeCleanupModel()
    private var browsers: [String: ChromePagesModel] = [:]

    func stopBrowserChecks() {
        for model in browsers.values where model.running { model.stop() }
    }

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
    case apps(AppsTab)
    case space(SpaceTab)
    case memory
    case claudeCleanup, privacyTools
    case compute(Bool)
    case history

    /// `--page` values: overview, sensors, fans, settings, pages, disk, disk:overview, disk:<category>,
    /// agents, agents:<area>, apps, apps:leftovers, space, space:large, space:duplicates, memory, cpu, gpu, claude-cleanup, history.
    init?(argument: String) {
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        guard let command = parts.first else { return nil }
        switch command {
        case "overview": self = .overview
        case "sensors": self = .sensors
        case "fans": self = .fans
        case "settings": self = .settings
        case "pages": self = .browser(parts.count > 1 ? parts[1] : "Google Chrome")
        case "disk": self = .disk(parts.count > 1 ? (DiskPage(argument: parts[1]) ?? .home) : .home)
        case "agents": self = .agents(parts.count > 1 ? (Area(rawValue: parts[1]).map { .area($0) } ?? .home) : .home)
        case "apps": self = .apps(parts.count > 1 ? (AppsTab(rawValue: parts[1]) ?? .installed) : .installed)
        case "memory": self = .memory
        case "history": self = .history
        case "claude-cleanup": self = parts.count > 1 && parts[1] == "privacy" ? .privacyTools : .claudeCleanup
        case "cpu": self = .compute(false)
        case "gpu": self = .compute(true)
        case "space": self = .space(parts.count > 1 ? (SpaceTab(rawValue: parts[1]) ?? .browse) : .browse)
        default: return nil
        }
    }

    var isDisk: Bool { if case .disk = self { return true } else { return false } }
    var isAgents: Bool { if case .agents = self { return true } else { return false } }
    var appsTab: AppsTab? { if case let .apps(t) = self { return t } else { return nil } }
    var spaceTab: SpaceTab? { if case let .space(t) = self { return t } else { return nil } }
}

/// The main window: everything Thermo does, in the Disk Cleanup look — a sidebar of places and a
/// page for each. The menu bar panel keeps the live numbers and a few quick controls.
@MainActor
enum MainWindow {
    private(set) static var window: NSWindow?
    static let state = State()
    static let minimumContentSize = NSSize(width: 800, height: 580)

    final class State: ObservableObject {
        @Published var page: MainPage = .overview
    }

    static func usableFrame(_ frame: NSRect, screens: [NSRect]) -> Bool {
        guard [frame.minX, frame.minY, frame.maxX, frame.maxY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width >= minimumContentSize.width, frame.height >= minimumContentSize.height else { return false }
        let desktop = screens.reduce(NSRect.null) { $0.union($1) }
        guard frame.width <= desktop.width, frame.height <= desktop.height else { return false }
        let titlebar = NSRect(x: frame.minX, y: frame.maxY - 28, width: frame.width, height: 28)
        return screens.contains { screen in
            let visible = frame.intersection(screen)
            let dragArea = titlebar.intersection(screen)
            return visible.width >= 320 && visible.height >= 160
                && dragArea.width >= 200 && dragArea.height >= 20
        }
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
                .frame(minWidth: minimumContentSize.width, maxWidth: .infinity,
                       minHeight: minimumContentSize.height, maxHeight: .infinity))
            host.sizingOptions = [.minSize]
            w.contentViewController = host
            // Snapshot windows neither read nor write the user's saved window placement.
            if offscreen {
                w.styleMask = [.borderless]
                let arguments = CommandLine.arguments
                let requested = arguments.firstIndex(of: "--snapshot-width").flatMap {
                    $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil
                }
                let width = requested.flatMap { $0.isFinite && $0 >= minimumContentSize.width && $0 <= 2200 ? $0 : nil } ?? 1100
                let requestedHeight = arguments.firstIndex(of: "--snapshot-height").flatMap {
                    $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil
                }
                let height = requestedHeight.flatMap { $0.isFinite && $0 >= minimumContentSize.height && $0 <= 1600 ? $0 : nil } ?? 740
                w.setFrame(NSRect(x: -6000, y: -6000, width: width, height: height), display: true)
            } else {
                if !w.setFrameUsingName("ThermoMain") || !usableFrame(w.frame, screens: NSScreen.screens.map(\.visibleFrame)) {
                    w.setContentSize(NSSize(width: 1100, height: 740))
                    w.center()
                }
                w.setFrameAutosaveName("ThermoMain")
            }
            // Live numbers only while the window can be seen.
            let center = NotificationCenter.default
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { models.monitor.windowOpen = w.isVisible && w.occlusionState.contains(.visible) }
            }
            center.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated {
                    models.monitor.windowOpen = false
                    models.stopBrowserChecks()
                    SpaceOverviewModel.shared.stop()
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
            let _ = L10n.apply(preference: language)
            MainView(page: $state.page, monitor: models.monitor, disk: models.disk, agents: models.agents, models: models)
                .id(language)
                .onAppear { installStandardMenus() }
                .onChange(of: language) { preference in
                    L10n.apply(preference: preference)
                    installStandardMenus()
                }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            WindowBackdrop(glow: glow, tint: tint)
            HStack(spacing: 0) {
                MainSidebar(page: $page, monitor: monitor, disk: disk, agents: agents)
                    .frame(width: 236).background(Color.black.opacity(0.22))
                Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
                VStack(spacing: 0) {
                    if let error = monitor.lastError {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(error).font(.callout).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if monitor.snapshot == nil {
                                Button(tr("Retry")) { monitor.sampleNow() }.buttonStyle(.bordered)
                            }
                            Button { monitor.lastError = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).help(tr("Dismiss"))
                                .accessibilityLabel(tr("Dismiss"))
                        }
                        .padding(14).glass(radius: 12).padding(.horizontal, 32).padding(.top, 40)
                    }
                    if page.isDisk, let error = disk.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14).glass(radius: 12)
                            .padding(.horizontal, 32).padding(.top, 12)
                    }
                    if cleanupNoticeNeeded {
                        HStack {
                            Text(disk.resultsNeedRefresh ? tr("Some paths could not be removed. Scan again to refresh the remaining items.") : disk.languageStale ? tr("Scan again to refresh results in the selected language.") : tr("Scan scope changed. Scan again to update these results.")).font(.callout)
                            Spacer()
                            Button(tr("Scan again")) { disk.scan(category: cleanupCategory) }.disabled(disk.scanning || disk.cleaning)
                        }
                        .padding(14).glass(radius: 12).padding(.horizontal, 32).padding(.top, 12)
                    }
                    ZStack { content }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: page)
        .onChange(of: page) { p in
            if p.isAgents { agents.scan(ifOlderThan: 60) }
            if p.isDisk, disk.report == nil, !disk.scanning { disk.loadSaved() }
        }
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
        default: return heatColor(monitor.snapshot?.maximumKnownTemperature).opacity(0.8)
        }
    }

    var cleanupCategory: CleanCategory? {
        if case let .disk(.category(category)) = page { return category }
        return nil
    }

    var cleanupNoticeNeeded: Bool {
        switch page {
        case .disk(.home), .disk(.category):
            return disk.scopeNeedsRefresh(category: cleanupCategory) || disk.resultsNeedRefresh || disk.languageStale
        default: return false
        }
    }

    func startClean() { if !disk.selectedItems.isEmpty { confirmingClean = true } }

    @ViewBuilder var content: some View {
        switch page {
        case .overview:
            OverviewPage(monitor: monitor, open: { page = $0 }).transition(.opacity)
        case .sensors:
            SensorsPage(monitor: monitor)
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
            DiskOverviewView(openCleanup: { category in
                SpaceOverviewModel.shared.stop()
                if !disk.scanning && !disk.cleaning { disk.scan(category: category) }
                page = category.map { .disk(.category($0)) } ?? .disk(.home)
            }, cleanupDisabled: disk.scanning || disk.cleaning).transition(.opacity)
        case let .disk(.category(c)):
            DiskCategoryPage(model: disk, category: c, clean: startClean).id(c)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        case .agents(.home):
            DiagnosticsHome(scanner: agents, open: { a in page = .agents(.area(a)) }).transition(.opacity)
        case let .agents(.area(a)):
            AreaPage(scanner: agents, area: a).id(a).transition(.opacity.combined(with: .move(edge: .trailing)))
        case let .apps(tab):
            AppsPage(model: models.apps, tab: Binding(get: { tab }, set: { page = .apps($0) })).transition(.opacity)
        case let .compute(gpu):
            ComputePage(gpu: gpu).id(gpu).transition(.opacity)
        case .memory:
            MemoryPage(model: MemoryModel.shared, open: { page = $0 }).transition(.opacity)
        case .claudeCleanup:
            ClaudeCleanupPage(model: models.claudeCleanup).transition(.opacity)
        case .privacyTools:
            ClaudeCleanupPage(model: models.claudeCleanup, initialTab: 1).transition(.opacity)
        case .history:
            HistoryPage(model: HistoryModel.shared, open: { page = $0 }).transition(.opacity)
        case let .space(tab):
            SpacePage(model: SpaceLensModel.shared, tab: Binding(get: { tab }, set: { page = .space($0) })).transition(.opacity)
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
    /// Share of memory in use; refreshed with the sidebar (the monitor ticks while the window is open).
    var memoryTrailing: String? {
        guard monitor.snapshot != nil, let m = SystemStats.memory() else { return nil }
        return String(format: "%.0f%%", Double(m.usedBytes) / Double(max(1, m.totalBytes)) * 100)
    }

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
                        trailing: monitor.snapshot.map { tempText($0.maximumKnownTemperature, fahrenheit: fahrenheit) })
                    row(.sensors, tr("Sensors"), "thermometer.medium", .red, trailing: nil)
                    row(.fans, tr("Fans"), "fan.fill", .blue,
                        trailing: monitor.snapshot?.fans.map(\.rpm).max().map { tr("%1$@ rpm", String(Int($0))) })

                    header(tr("Resources"))
                    row(.compute(false), tr("CPU usage"), "cpu", .cyan, trailing: nil)
                    row(.compute(true), tr("GPU usage"), "cpu.fill", .purple, trailing: nil)
                    row(.memory, tr("Memory usage"), "memorychip.fill", .green, trailing: memoryTrailing)
                    row(.browser("Google Chrome"), tr("Tab organizer"), "rectangle.stack.fill", .teal, trailing: nil)

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

                    row(.space(page.spaceTab ?? .browse), tr("Space Lens"), "square.grid.3x3.topleft.filled", .cyan, trailing: nil,
                        selected: page.spaceTab != nil)
                    row(.apps(page.appsTab ?? .installed), tr("Uninstall apps"), "square.grid.2x2.fill", .indigo, trailing: nil,
                        selected: page.appsTab != nil)

                    header(tr("AI Agent Diagnostics"))
                    row(.claudeCleanup, tr("Claude cleanup"), "arrow.counterclockwise.circle.fill", .orange, trailing: nil,
                        selected: page == .claudeCleanup || page == .privacyTools)
                    row(.agents(.home), tr("Smart Check"), "stethoscope", .purple, trailing: nil, badge: agents.report?.problemCount ?? 0)
                    if page.isAgents {
                        ForEach(Area.allCases, id: \.self) { a in
                            row(.agents(.area(a)), AgentStyle.title(a), AgentStyle.icon(a), AgentStyle.tint(a), trailing: nil,
                                badge: agents.report?.problemCount(in: a) ?? 0, indent: true)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.horizontal, 12)
            VStack(spacing: 2) {
                row(.history, tr("History"), "clock.arrow.circlepath", .brown, trailing: nil)
                row(.settings, tr("Settings"), "gearshape.fill", .gray, trailing: nil)
            }.padding(.vertical, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    func header(_ title: String) -> some View {
        // Upper case only reads well in Latin script ("AI AGENT 诊断" does not).
        Text(L10n.current == .english ? title.uppercased() : title).font(.system(size: 10, weight: .semibold)).tracking(0.8)
            .foregroundStyle(.white.opacity(0.4)).padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 6)
    }

    func row(_ target: MainPage, _ title: String, _ symbol: String, _ color: Color, trailing: String?,
             badge: Int = 0, indent: Bool = false, selected: Bool? = nil) -> some View {
        let on = selected ?? (page == target)
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
        .accessibilityLabel(title)
        .accessibilityValue(on ? tr("Selected") : "")
        .help(title)
        .background(shortcut(target))
        .padding(.horizontal, 8)
    }
    @ViewBuilder func shortcut(_ target: MainPage) -> some View {
        switch target {
        case .overview: key("1", target)
        case .sensors: key("2", target)
        case .fans: key("3", target)
        case .browser("Google Chrome"): key("4", target)
        case .disk(.home): key("5", target)
        case .agents(.home): key("6", target)
        case .settings: key(",", target)
        default: EmptyView()
        }
    }

    func key(_ key: KeyEquivalent, _ target: MainPage) -> some View {
        Button("") { page = target }.keyboardShortcut(key, modifiers: .command)
            .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }

}

// MARK: - Sensors

/// Every sensor, a glass card per group with its hottest reading up top; power, voltage and current after.
struct SensorsPage: View {
    @ObservedObject var monitor: Monitor
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false

    @AppStorage(Settings.unnamedSensors) private var includeUnnamed = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        WindowPage(title: tr("Sensors"), subtitle: monitor.model) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(tr("Search sensors by name or key"), text: $search)
                    .textFieldStyle(.plain).focused($searchFocused)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help(tr("Clear search")).accessibilityLabel(tr("Clear search"))
                }
            }
            .padding(12).glass(radius: 10)
            .background(Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true))
            HStack {
                Toggle(tr("Include unnamed sensors"), isOn: $includeUnnamed).toggleStyle(.switch)
                Spacer()
                Text(tr("Refresh: %1$@ s", String(format: "%g", monitor.interval))).font(.caption).foregroundStyle(.secondary)
            }
            if let s = monitor.snapshot {
                if let battery = s.battery, BatteryDetails.matches(query: search) {
                    BatteryDetails(battery: battery, fahrenheit: fahrenheit)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(SensorGroup.allCases, id: \.self) { g in
                        let rows = s.temperatures.filter { $0.group == g && matches($0) }
                        if !rows.isEmpty {
                            let hot = rows.map(\.value).max()
                            card(groupName(g), symbol: symbol(g), headline: tempText(hot, fahrenheit: fahrenheit), color: heatColor(hot),
                                 rows: rows.map { ($0.name, $0.key, tempText($0.value, fahrenheit: fahrenheit), heatColor($0.value)) })
                        }
                    }
                    electrical(tr("Power"), "bolt.fill", s.power, "%.2f W")
                    electrical(tr("Voltage"), "powerplug.fill", s.voltages, "%.3f V")
                    electrical(tr("Current"), "waveform.path.ecg", s.currents, "%.3f A")
                    if !s.temperatures.contains(where: matches)
                        && !s.power.contains(where: { matches($0, category: tr("Power")) })
                        && !s.voltages.contains(where: { matches($0, category: tr("Voltage")) })
                        && !s.currents.contains(where: { matches($0, category: tr("Current")) })
                        && !(s.battery != nil && BatteryDetails.matches(query: search)) {
                        Label(tr("No matching sensors"), systemImage: "magnifyingglass")
                            .foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity).glass()
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .onAppear { monitor.showUnnamedSensors(includeUnnamed) }
        .onChange(of: includeUnnamed) { monitor.showUnnamedSensors($0) }
        .onDisappear { monitor.showUnnamedSensors(false) }
    }

    func matches(_ reading: Reading) -> Bool { matches(reading, category: nil) }

    func matches(_ reading: Reading, category: String?) -> Bool {
        SensorSearch.matches(reading, query: search, category: category)
    }

    func symbol(_ g: SensorGroup) -> String {
        switch g {
        case .cpu: return "cpu"
        case .gpu: return "cpu.fill"
        case .memory: return "memorychip"
        case .storage: return "internaldrive"
        case .battery: return "battery.75"
        case .ambient: return "wind"
        case .board: return "rectangle.connected.to.line.below"
        case .other: return "thermometer.medium"
        }
    }

    @ViewBuilder func electrical(_ title: String, _ symbol: String, _ rows: [Reading], _ f: String) -> some View {
        let rows = rows.filter { matches($0, category: title) }
        if !rows.isEmpty {
            card(title, symbol: symbol, headline: nil, color: .yellow,
                 rows: rows.map { ($0.name, $0.key, String(format: f, $0.value), Color.white.opacity(0.9)) })
        }
    }

    func card(_ title: String, symbol: String, headline: String?, color: Color,
              rows: [(String, String, String, Color)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, color: color, size: 28)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                if let headline {
                    Text(headline).font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(color)
                }
            }
            VStack(spacing: 5) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    HStack(spacing: 8) {
                        Text(r.0).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).lineLimit(1).help(r.0)
                        Spacer(minLength: 4)
                        if !r.1.hasPrefix("hid:") {
                            Text(r.1).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).textSelection(.enabled)
                        }
                        Text(r.2).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(r.3)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            }
        }
        .padding(16)
        .glass(radius: 16)
    }
}

/// Search accepts displayed category names as well as hardware names and SMC keys.
enum SensorSearch {
    static func matches(_ reading: Reading, query: String, category: String? = nil) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || reading.name.localizedCaseInsensitiveContains(query)
            || reading.key.localizedCaseInsensitiveContains(query)
            || groupName(reading.group).localizedCaseInsensitiveContains(query)
            || category?.localizedCaseInsensitiveContains(query) == true
    }
}
