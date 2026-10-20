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
    lazy var disk = DiskModel(retentionPreferences:.stored(in:.standard))
    lazy var agents = AgentScanner()
    lazy var apps = AppsModel()
    lazy var startup = StartupItemsModel()
    lazy var softwareUpdates = AppUpdatesModel()
    lazy var nativeUpdates = NativeUpdatesModel()
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
    case connections

    /// `--page` values: overview, sensors, fans, settings, pages, disk, disk:overview, disk:<category>,
    /// agents, agents:<area>, apps, apps:leftovers, space, space:large, space:duplicates, memory, cpu, gpu, claude-cleanup, history, connections.
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
        case "apps": self = .apps(parts.count > 1 ? (parts[1] == "feeds" ? .updates : AppsTab(rawValue: parts[1]) ?? .installed) : .installed)
        case "memory": self = .memory
        case "history": self = .history
        case "connections": self = .connections
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
        /// A tool panel asked for from outside the window (the menu bar menu); shown as a sheet.
        @Published var tool: ToolSheet?
    }

    /// Opens the window and shows one of the menu bar tools in it.
    static func show(tool: ToolSheet) {
        show()
        state.tool = tool
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

    /// Keep the window placement, but release page-local state and appearance-owned tasks.
    static func retireContent(in window: NSWindow) {
        let bounds = window.contentView?.bounds ?? .zero
        window.contentViewController = nil
        window.contentView = NSView(frame: bounds)
    }

    static func restoreContent(in window: NSWindow, make: () -> NSViewController) {
        guard window.contentViewController == nil else { return }
        window.contentViewController = make()
    }

    private static func installContent(in window: NSWindow, models: AppModels) {
        restoreContent(in: window) {
            let host = NSHostingController(rootView: Host(state: state, models: models)
                .frame(minWidth: minimumContentSize.width, maxWidth: .infinity,
                       minHeight: minimumContentSize.height, maxHeight: .infinity))
            host.sizingOptions = [.minSize]
            return host
        }
    }

    static func show(_ page: MainPage? = nil) {
        (NSApp.delegate as? AppDelegate)?.closeMenuPanel()
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
            installContent(in: w, models: models)
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
                    models.apps.retire()
                    models.startup.retire()
                    models.softwareUpdates.retire()
                    models.nativeUpdates.retire()
                    SpaceOverviewModel.shared.stop()
                    SpaceLensModel.shared.stop()
                    SpaceLensModel.shared.stopDuplicates()
                    MemoryModel.shared.stop()
                    ConnectionsModel.shared.stop()
                    ComputeModel.shared.stop()
                    retireContent(in: w)
                }
            }
            window = w
        }
        if let window { installContent(in: window, models: models) }
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
                .sheet(item: $state.tool) { tool in
                    switch tool {
                    case .keepAwake: IdleAwakePanel(model: IdleAwakeModel.shared)
                    case .cleanScreen: CleanScreenSetupView(model: CleanScreenModel.shared)
                    case .lowLatency: AWDLPanel(model: AWDLModel.shared)
                    case .batteryCare: BatteryCarePanel(model: BatteryCareModel.shared)
                    }
                }
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
    @State private var cleanReview: DiskCleanupReview?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            WindowBackdrop(glow: glow, tint: tint)
            HStack(spacing: 0) {
                MainSidebar(page: $page, monitor: monitor, disk: disk, agents: agents)
                    .frame(width: 228).background(Theme.sidebar.opacity(0.92))
                Rectangle().fill(Theme.hairline).frame(width: 1)
                VStack(spacing: 0) {
                    if let error = monitor.lastError {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.caution)
                            Text(error).font(Theme.body).textSelection(.enabled)
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
                            .font(Theme.body).foregroundStyle(Theme.caution).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14).glass(radius: 12)
                            .padding(.horizontal, 32).padding(.top, 12)
                    }
                    if cleanupNoticeNeeded {
                        HStack {
                            Text(disk.resultsNeedRefresh ? tr("Some paths could not be removed. Scan again to refresh the remaining items.") : disk.languageStale ? tr("Scan again to refresh results in the selected language.") : tr("Scan scope changed. Scan again to update these results.")).font(Theme.body)
                            Spacer()
                            Button(tr("Scan again")) { disk.scan(category: cleanupCategory) }.disabled(disk.scanning || disk.cleaning)
                        }
                        .padding(14).glass(radius: 12).padding(.horizontal, 32).padding(.top, 12)
                    }
                    // Only the page swap animates; the sidebar and banners keep still.
                    ZStack { content }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .animation(Theme.standard.unlessReduced(reduceMotion), value: page)
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onChange(of: page) { p in
            if p.isAgents { agents.scan(ifOlderThan: 60) }
            if p.isDisk, disk.report == nil, !disk.scanning { disk.loadSaved(category: cleanupCategory) }
        }
        .onAppear {
            if page.isAgents { agents.scan(ifOlderThan: 60) }
            if page.isDisk, disk.report == nil, !disk.scanning { disk.loadSaved(category: cleanupCategory) }
        }
        .sheet(item: $cleanReview) { review in
            DiskCleanConfirmation(review: review,
                                  confirm: { cleanReview = nil; disk.clean(review: review) }, cancel: { cleanReview = nil })
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

    func startClean() { if cleanReview == nil { cleanReview = disk.cleanupReview() } }

    @ViewBuilder var content: some View {
        switch page {
        case .overview:
            OverviewPage(monitor: monitor, open: { page = $0 }).transition(.page)
        case .sensors:
            SensorsPage(monitor: monitor).transition(.page)
        case .fans:
            WindowPage(title: tr("Fans"), subtitle: tr("Choose how fast each fan runs. Settings stay when Thermo quits or updates.")) {
                FansView(monitor: monitor)
            }.transition(.page)
        case .settings:
            WindowPage(title: tr("Settings"), subtitle: "Thermo \(AppInfo.version)") {
                SettingsView(disk: disk, monitor: monitor, updates: models.updates)
            }.transition(.page)
        case let .browser(app):
            ChromePagesView(model: models.browser(app), embedded: true).id(app).transition(.page)
        case .disk(.home):
            DiskHome(model: disk, open: { page = .disk(.category($0)) }, clean: startClean).transition(.page)
        case .disk(.overview):
            DiskOverviewView(openCleanup: { category in
                SpaceOverviewModel.shared.stop()
                if !disk.scanning && !disk.cleaning { disk.scan(category: category) }
                page = category.map { .disk(.category($0)) } ?? .disk(.home)
            }, cleanupDisabled: disk.scanning || disk.cleaning).transition(.page)
        case let .disk(.category(c)):
            DiskCategoryPage(model: disk, category: c, clean: startClean).id(c)
                .transition(.page)
        case .agents(.home):
            DiagnosticsHome(scanner: agents, open: { a in page = .agents(.area(a)) }).transition(.page)
        case let .agents(.area(a)):
            AreaPage(scanner: agents, area: a).id(a).transition(.page)
        case let .apps(tab):
            AppsPage(model: models.apps, startup: models.startup, updates: models.softwareUpdates, native: models.nativeUpdates,
                     tab: Binding(get: { tab }, set: { page = .apps($0) })).transition(.page)
        case let .compute(gpu):
            ComputePage(gpu: gpu).id(gpu).transition(.page)
        case .memory:
            MemoryPage(model: MemoryModel.shared, open: { page = $0 }).transition(.page)
        case .claudeCleanup:
            ClaudeCleanupPage(model: models.claudeCleanup).transition(.page)
        case .privacyTools:
            ClaudeCleanupPage(model: models.claudeCleanup, initialTab: 1).transition(.page)
        case .connections:
            ConnectionsPage(model: ConnectionsModel.shared).transition(.page)
        case .history:
            HistoryPage(model: HistoryModel.shared, open: { page = $0 }).transition(.page)
        case let .space(tab):
            SpacePage(model: SpaceLensModel.shared, tab: Binding(get: { tab }, set: { page = .space($0) })).transition(.page)
        }
    }
}

/// A plain page: the shared header, then its content, scrolling.
struct WindowPage<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PageHeader(title: title, subtitle: subtitle)
                content()
            }
            .frame(maxWidth: Theme.pageWidth, alignment: .leading)
            .padding(.horizontal, Theme.pagePadding).padding(.top, Theme.pageTop).padding(.bottom, 32)
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

    @Namespace private var selectionSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "thermometer.medium").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [Theme.caution, Theme.danger], startPoint: .top, endPoint: .bottom))
                Text("Thermo").font(Theme.rowTitle.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 18).padding(.top, 46).padding(.bottom, 10)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    row(.overview, tr("Overview"), "gauge.with.dots.needle.67percent", .orange,
                        trailing: monitor.snapshot.map { tempText($0.maximumKnownTemperature, fahrenheit: fahrenheit) },
                        trailingColor: monitor.snapshot.map { heatColor($0.maximumKnownTemperature) })
                    row(.sensors, tr("Sensors"), "thermometer.medium", .red, trailing: nil)
                    row(.fans, tr("Fans"), "fan", .blue,
                        trailing: monitor.snapshot.flatMap { FanControlPresentation.speedSummary($0.fans) })
                    row(.connections, tr("Connections"), "wifi", .blue, trailing: nil)

                    header(tr("Resources"))
                    row(.compute(false), tr("CPU usage"), "cpu", .cyan, trailing: nil)
                    row(.compute(true), tr("GPU usage"), "square.stack.3d.up", .purple, trailing: nil)
                    row(.memory, tr("Memory usage"), "memorychip", .green, trailing: memoryTrailing)
                    row(.browser("Google Chrome"), tr("Tab organizer"), "rectangle.stack", .teal, trailing: nil)

                    header(tr("Disk Cleanup"))
                    row(.disk(.home), tr("Smart Scan"), "sparkles", .pink, trailing: disk.report.map { ByteFormat.string($0.totalBytes) })
                    if page.isDisk {
                        row(.disk(.overview), tr("Where the space is"), "chart.pie", .teal, trailing: nil, indent: true)
                        ForEach(CleanCategory.allCases, id: \.self) { c in
                            let bytes = disk.report?.bytes(in: c) ?? 0
                            // Retention is configured here, so this entry cannot depend on
                            // a scan having found conversations eligible for removal.
                            if c == .aiSessions || bytes > 0 || items.contains(where: { $0.category == c }) {
                                let size: String? = c == .aiSessions && disk.sessionRetentionDays == nil ? nil : ByteFormat.string(bytes)
                                row(.disk(.category(c)), c.title, DiskStyle.icon(c), DiskStyle.tint(c), trailing: size, indent: true)
                            }
                        }
                    }

                    row(.space(page.spaceTab ?? .browse), tr("Space Lens"), "square.grid.3x3.topleft.filled", .cyan, trailing: nil,
                        selected: page.spaceTab != nil)
                    row(.apps(page.appsTab ?? .installed), tr("Software"), "square.grid.2x2", .indigo, trailing: nil,
                        selected: page.appsTab != nil)

                    header(tr("AI Agent Diagnostics"))
                    row(.claudeCleanup, tr("Claude cleanup"), "arrow.counterclockwise.circle", .orange, trailing: nil,
                        selected: page == .claudeCleanup || page == .privacyTools)
                    row(.agents(.home), tr("Smart Check"), "stethoscope", .purple, trailing: nil, badge: agents.report?.problemCount ?? 0)
                    if page.isAgents {
                        ForEach(Area.allCases, id: \.self) { a in
                            row(.agents(.area(a)), AgentStyle.title(a), AgentStyle.icon(a), AgentStyle.tint(a), trailing: nil,
                                badge: agents.report?.problemCount(in: a) ?? 0, indent: true)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
            // Rows scrolling under the footer fade out instead of being cut in half.
            .mask(VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
            })
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 14)
            VStack(spacing: 1) {
                row(.history, tr("History"), "clock.arrow.circlepath", .brown, trailing: nil)
                row(.settings, tr("Settings"), "gearshape", .gray, trailing: nil)
            }.padding(.vertical, 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(Theme.standard.unlessReduced(reduceMotion), value: page)
    }

    func header(_ title: String) -> some View {
        // Upper case only reads well in Latin script ("AI AGENT 诊断" does not).
        Text(L10n.current == .english ? title.uppercased() : title).font(Theme.label.weight(.semibold))
            .tracking(L10n.current == .english ? 0.6 : 0)
            .foregroundStyle(Theme.textTertiary).padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    /// One place in the sidebar. Icons stay grey so the list reads as one column; the selected
    /// row's icon takes its color, and the selection slides from row to row.
    func row(_ target: MainPage, _ title: String, _ symbol: String, _ color: Color, trailing: String?,
             trailingColor: Color? = nil, badge: Int = 0, indent: Bool = false, selected: Bool? = nil) -> some View {
        let on = selected ?? (page == target)
        return Button { page = target } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: indent ? 12 : 13, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(on ? color : Theme.textSecondary)
                    .frame(width: 18)
                Text(title).font((indent ? Theme.secondary : Theme.body).weight(on ? .semibold : .regular))
                    .foregroundStyle(on ? Theme.textPrimary : Theme.textPrimary.opacity(0.78))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)").font(Theme.label.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 16)
                        .background(Capsule().fill(Theme.caution.opacity(0.9)))
                        .contentTransition(.numericText())
                } else if let trailing {
                    Text(trailing).font(Theme.label.monospacedDigit())
                        .foregroundStyle((trailingColor ?? Theme.textTertiary).opacity(trailingColor == nil ? 1 : 0.9))
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 10).frame(height: indent ? 26 : 30)
            .padding(.leading, indent ? 14 : 0)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surfaceRaised)
                        .matchedGeometryEffect(id: "selection", in: selectionSpace)
                }
            }
            .hoverHighlight(radius: 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// Every sensor, one inspector panel per group with its hottest reading in the header; power,
/// voltage and current after.
struct SensorsPage: View {
    @ObservedObject var monitor: Monitor
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false

    @AppStorage(Settings.unnamedSensors) private var includeUnnamed = false
    @State private var search = ""

    var body: some View {
        WindowPage(title: tr("Sensors"), subtitle: monitor.model) {
            if let s = monitor.snapshot {
                hero(s)
                controls
                if let battery = s.battery, BatteryDetails.matches(query: search) {
                    BatteryDetails(battery: battery, fahrenheit: fahrenheit)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: Theme.Space.l, alignment: .top)], alignment: .leading,
                          spacing: Theme.Space.l) {
                    ForEach(SensorGroup.allCases, id: \.self) { g in
                        let rows = s.temperatures.filter { $0.group == g && matches($0) }
                        if !rows.isEmpty {
                            let hot = rows.map(\.value).max()
                            section(groupName(g), headline: tempText(hot, fahrenheit: fahrenheit), color: heatColor(hot),
                                    rows: rows.map { ($0.name, $0.key, tempText($0.value, fahrenheit: fahrenheit), heatColor($0.value)) })
                        }
                    }
                    electrical(tr("Power"), s.power, "%.2f W")
                    electrical(tr("Voltage"), s.voltages, "%.3f V")
                    electrical(tr("Current"), s.currents, "%.3f A")
                }
                if !s.temperatures.contains(where: matches)
                    && !s.power.contains(where: { matches($0, category: tr("Power")) })
                    && !s.voltages.contains(where: { matches($0, category: tr("Voltage")) })
                    && !s.currents.contains(where: { matches($0, category: tr("Current")) })
                    && !(s.battery != nil && BatteryDetails.matches(query: search)) {
                    InspectorPanel { EmptyState(symbol: "magnifyingglass", title: tr("No matching sensors")) }
                }
            } else {
                controls
                SkeletonList(rows: 6)
            }
        }
        .onAppear { monitor.showUnnamedSensors(includeUnnamed) }
        .onChange(of: includeUnnamed) { monitor.showUnnamedSensors($0) }
        .onDisappear { monitor.showUnnamedSensors(false) }
    }

    /// The hottest sensor in large type, then the hottest reading of each group beside it.
    func hero(_ s: Snapshot) -> some View {
        let hottest = s.temperatures.filter { $0.value.isFinite }.max { $0.value < $1.value }
        let groups: [(String, Double)] = SensorGroup.allCases.compactMap { g in
            s.temperatures.filter { $0.group == g && $0.value.isFinite }.map(\.value).max().map { (groupName(g), $0) }
        }
        return InspectorPanel {
            HStack(alignment: .center, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(tr("Hottest sensor")).font(Theme.label).foregroundStyle(Theme.textTertiary)
                    Text(tempText(hottest?.value, fahrenheit: fahrenheit)).font(Theme.figure(.hero))
                        .foregroundStyle(hottest == nil ? Theme.textTertiary : heatColor(hottest?.value))
                        .contentTransition(.numericText())
                        .animation(Theme.gentle, value: hottest?.value)
                    if let hottest {
                        Text(hottest.name).font(Theme.secondary).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                .frame(minWidth: 150, alignment: .leading)
                .accessibilityElement(children: .combine)
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 56)
                // One row when it fits, otherwise even rows of three.
                let columns = groups.count <= 3 ? max(1, groups.count) : groups.count <= 6 ? (groups.count + 1) / 2 : 4
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.l, alignment: .leading), count: columns),
                          alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(groups, id: \.0) { name, value in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                            Text(tempText(value, fahrenheit: fahrenheit)).font(Theme.figure(.large))
                                .foregroundStyle(heatColor(value)).contentTransition(.numericText())
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(Theme.Space.l)
        }
    }

    var controls: some View {
        HStack(spacing: Theme.Space.m) {
            SearchField(text: $search, prompt: tr("Search sensors by name or key"))
            Toggle(tr("Include unnamed sensors"), isOn: $includeUnnamed).toggleStyle(.switch).controlSize(.mini)
                .font(Theme.secondary).foregroundStyle(Theme.textSecondary).fixedSize()
            Text(tr("Refresh: %1$@ s", String(format: "%g", monitor.interval)))
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize()
        }
    }

    func matches(_ reading: Reading) -> Bool { matches(reading, category: nil) }

    func matches(_ reading: Reading, category: String?) -> Bool {
        SensorSearch.matches(reading, query: search, category: category)
    }

    @ViewBuilder func electrical(_ title: String, _ rows: [Reading], _ f: String) -> some View {
        let rows = rows.filter { matches($0, category: title) }
        if !rows.isEmpty {
            section(title, headline: nil, color: Theme.textPrimary,
                    rows: rows.map { ($0.name, $0.key, String(format: f, $0.value), Theme.textPrimary) })
        }
    }

    func section(_ title: String, headline: String?, color: Color,
                 rows: [(String, String, String, Color)]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: title) {
                if let headline {
                    Text(headline).font(Theme.sectionTitle.monospacedDigit()).foregroundStyle(color)
                        .accessibilityLabel(tr("hottest") + " " + headline)
                }
            }
            InspectorPanel {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    if i > 0 { InspectorDivider(inset: Theme.Space.l) }
                    HStack(spacing: Theme.Space.s) {
                        Text(r.0).font(Theme.secondary).foregroundStyle(Theme.textPrimary).lineLimit(1).help(r.0)
                        Spacer(minLength: Theme.Space.xs)
                        if !r.1.hasPrefix("hid:") {
                            Text(r.1).font(Theme.mono).foregroundStyle(Theme.textTertiary)
                                .lineLimit(1).textSelection(.enabled)
                        }
                        Text(r.2).font(Theme.figure(.row)).foregroundStyle(r.3).contentTransition(.numericText())
                            .frame(width: 60, alignment: .trailing)
                    }
                    .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
                    .accessibilityElement(children: .combine)
                }
            }
        }
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
