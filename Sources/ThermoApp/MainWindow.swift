import ThermoKernel
import SystemServicesAPI
import ThermoUI
import ModuleKit
import NativeFeatureAPI
import ModuleHost
import AgentDoctor
import AppKit
import SwiftUI
import ThermoKit
import ThermoL10n

/// Where the main window is.
enum MainPage: Hashable {
    case settings
    case native(NativeFeatureRoute)
    /// Only isolated external modules use this representation.
    case module(String,String)
    static var overview:MainPage {.native(.init(BuiltinModuleManifests.performance.id,"overview"))}
    static var sensors:MainPage {.native(.init(BuiltinModuleManifests.performance.id,"sensors"))}
    static var fans:MainPage {.native(.init(BuiltinModuleManifests.performance.id,"fans"))}
    static var memory:MainPage {.native(.init(BuiltinModuleManifests.performance.id,"memory"))}
    static func compute(_ gpu:Bool)->MainPage {.native(.init(BuiltinModuleManifests.performance.id,gpu ? "gpu":"cpu"))}
    static func browser(_ app:String)->MainPage {.native(.init(BuiltinModuleManifests.browser.id,"home",context:["app":.text(app)]))}

    init?(argument:String) {
        if argument=="settings" {self = .settings;return}
        if let route=try? BuiltinNativeFeatures.catalog.resolveLegacyPage(argument) {self = .native(route);return}
        guard argument.hasPrefix("module:") else{return nil}
        let parts=argument.dropFirst(7).split(separator:":",maxSplits:1,omittingEmptySubsequences:false).map(String.init)
        guard let id=parts.first,!id.isEmpty else{return nil}
        let page=MainPage.module(id,parts.count>1 ? parts[1]:"")
        if BuiltinNativeFeatures.catalog.manifest(id) != nil {
            guard let route=page.nativeRoute else{return nil};self = .native(route)
        } else {self=page}
    }
    var nativeRoute:NativeFeatureRoute? {
        let catalog=BuiltinNativeFeatures.catalog
        switch self {
        case let .native(route):return try? catalog.normalize(route)
        case let .module(id,entry):
            guard let manifest=catalog.manifest(id),let selected=manifest.entries.first(where:{$0.kind == .page && (entry.isEmpty ? $0.parent==nil:$0.id==entry)}) else{return nil}
            return try? catalog.normalize(.init(id,selected.id))
        case .settings:return nil
        }
    }
    var module:String? {
        switch self {case let .native(route):return route.module;case let .module(id,_):return id;case .settings:return nil}
    }
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
        @Published var visible = false
    }

    /// Tool sheets need a stable NSWindow. A sheet attached to an NSPopover can
    /// expose its accessibility tree while drawing a completely blank surface.
    /// Close the menu panel in show() before presenting through this shared host.
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

    /// Native occlusion and lifecycle verification use the same visibility signal.
    static func setSamplingVisibility(_ visible: Bool) {
        if state.visible != visible { state.visible = visible }
        AppModels.shared.system.windowOpen = visible
        AppModels.shared.nativeFeatures.setWindowPresentation(visible: visible, selection: state.page.nativeRoute)
    }

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

    @discardableResult static func showNative(_ request:NativePresentationRequest)->Bool {
        guard let canonical=try? BuiltinNativeFeatures.catalog.normalizePresentation(request),
              NSApp.modalWindow == nil,window?.attachedSheet == nil,
              AppModels.shared.nativeFeatures.preparePresentation(canonical) else{return false}
        show(.native(canonical.route));return true
    }
    /// A trusted follow-up may select an off page, but cannot instantiate or prepare its feature.
    @discardableResult static func showRegistered(_ request:NativePresentationRequest)->Bool {
        guard let canonical=try? BuiltinNativeFeatures.catalog.normalizePresentation(request),
              NSApp.modalWindow==nil,window?.attachedSheet==nil else{return false}
        let store=AppModels.shared.nativeFeatures
        if store.canPresent(canonical.route),!store.preparePresentation(canonical){return false}
        show(.native(canonical.route));return true
    }
    static func show(_ page: MainPage? = nil) {
        if case .native?=page,page?.nativeRoute == nil{return}
        if let normalized=page?.nativeRoute {showCanonical(.native(normalized));return}
        showCanonical(page)
    }
    private static func showCanonical(_ page:MainPage?) {
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
                MainActor.assumeIsolated {
                    let visible = w.isVisible && (offscreen || w.occlusionState.contains(.visible))
                    setSamplingVisibility(visible)
                }
            }
            center.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated {
                    setSamplingVisibility(false)
                    models.nativeFeatures.retireVisibility()
                    retireContent(in: w)
                }
            }
            window = w
        }
        if let window { installContent(in: window, models: models) }
        window?.title = "Thermo"
        models.system.windowOpen = true
        if offscreen {
            window?.orderBack(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
        if let window {
            setSamplingVisibility(window.isVisible && (offscreen || window.occlusionState.contains(.visible)))
        }
    }

    /// Verification: once `ready`, lets animations settle, writes the window as a PNG and quits.
    static func snapshot(to path: String, when ready: @escaping @MainActor () -> Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                guard ready() else { return snapshot(to: path, when: ready) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    Task { @MainActor in
                        do {
                            guard let view = window?.contentView else { throw ModuleError.failed("no main window") }
                            let png = try await ModuleCenter.shared.manager.snapshot(in: view)
                            try png.write(to: URL(fileURLWithPath: path))
                            exit(0)
                        } catch {
                            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                            exit(2)
                        }
                    }
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
            MainView(page: $state.page, monitor: models.system, models: models)
                .environment(\.windowSamplingActive, state.visible)
                .onChange(of: state.page) {
                    models.nativeFeatures.setWindowPresentation(visible: state.visible, selection: $0.nativeRoute)
                }
                .id(language)
                .sheet(item: $state.tool) { tool in
                    switch tool {
                    case .keepAwake: IdleAwakePanel(model: IdleAwakeModel.shared)
                    case .cleanScreen: CleanScreenSetupView(model: CleanScreenModel.shared)
                    case .lowLatency: AWDLPanel(model: AWDLModel.shared)
                    case .batteryCare: BatteryCarePanel(model: BatteryCareModel.shared)
                    case .focus: FocusPanel(model: FocusTimerModel.shared)
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
    let monitor: SystemPresentation
    let models: AppModels
    @ObservedObject private var modules = ModuleCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let nativeUI=models.nativeFeatures.windowUI(selection:page.nativeRoute,locations:Set(NativeSidebarLocation.allCases))
        ZStack {
            if let backdrop=nativeUI.backdrop {backdrop}
            else {MainBackdrop(glow:false,overrideTint:nil,monitor:monitor)}
            HStack(spacing: 0) {
                MainSidebar(page: $page, monitor: monitor,nativeGroups:nativeUI.sidebar)
                    .frame(width: 228).background(Theme.sidebar.opacity(0.92))
                Rectangle().fill(Theme.hairline).frame(width: 1)
                VStack(spacing: 0) {
                    MonitorErrorBanner(monitor: monitor)
                    // Only the page swap animates; the sidebar and banners keep still.
                    ZStack { content }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .animation(Theme.standard.unlessReduced(reduceMotion), value: page)
                }
            }
            nativeUI.overlay
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)

    }

    @ViewBuilder var content: some View {
        if let route=page.nativeRoute {
            if let view=models.nativeFeatures.page(route) {view.id(route).transition(.page)}
            else {ModuleOffView().transition(.page)}
        } else { coreContent }
    }

    @ViewBuilder var coreContent: some View {
        switch page {
        case .settings:
            WindowPage(title: tr("Settings"), subtitle: "Thermo \(AppInfo.version)") {
                SettingsView(monitor: monitor, updates: models.updates).onAppear{monitor.refreshHelper()}
            }.transition(.page)
        case .native:
            ModuleOffView().transition(.page)
        case let .module(id, entry):
            if BuiltinNativeFeatures.catalog.manifest(id)==nil {
                ModulePageView(center:.shared,module:id,entry:entry).id(id+":"+entry).transition(.page)
            } else {ModuleOffView().transition(.page)}
        }
    }
}

private struct MainBackdrop: View {
    let glow: Bool
    let overrideTint: Color?
    @ObservedObject var monitor: SystemPresentation
    var body: some View {
        WindowBackdrop(glow: glow, tint: overrideTint ?? heatColor(monitor.snapshot?.maximumKnownTemperature).opacity(0.8))
    }
}

private struct MonitorErrorBanner: View {
    @ObservedObject var monitor: SystemPresentation
    var body: some View {
        if let error = monitor.lastError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.caution)
                Text(FanPolicyText.error(error)).help(error).font(Theme.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if monitor.snapshot == nil {
                    Button(tr("Retry")) { monitor.sampleNow() }.buttonStyle(.bordered)
                }
                Button { monitor.lastError = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help(tr("Dismiss")).accessibilityLabel(tr("Dismiss"))
            }
            .padding(14).glass(radius: 12).padding(.horizontal, 32).padding(.top, 40)
        }
    }
}

// MARK: - Sidebar

struct MainSidebar: View {
    @Binding var page: MainPage
    @ObservedObject var monitor: SystemPresentation
    var nativeGroups:[NativeSidebarGroup]=[]
    @AppStorage(Settings.fahrenheit) private var fahrenheit = false
    @ObservedObject private var modules = ModuleCenter.shared

    @Namespace private var selectionSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder func moduleRows(_ section: NativeSidebarLocation, titled: Bool = false) -> some View {
        ForEach(nativeGroups.filter{$0.location==section}) {group in
            if titled {header(tr(group.manifest.name))}
            group.content {item in
                AnyView(row(.native(item.route),tr(item.entry.title),item.entry.symbol ?? item.manifest.symbol,item.tint,trailing:item.trailing,trailingColor:item.trailingColor,badge:item.badge,indent:item.entry.parent != nil,selected:item.selected,activate:item.open)
                    .padding(.leading,CGFloat(max(0,item.manifest.depth(of:item.entry.id)-1))*14))
            }
        }

    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "thermometer.medium").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [Theme.caution, Theme.danger], startPoint: .top, endPoint: .bottom))
                Text("Thermo").font(Theme.rowTitle.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 18).padding(.top, 42).padding(.bottom, 8)
            ScrollViewReader { scroller in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    moduleRows(.overview)
                    moduleRows(.machine)

                    header(tr("Resources"))
                    moduleRows(.resources)

                    if !nativeGroups.contains(where:{$0.location == .storage}) {
                        header(tr("Storage & apps"))
                    }
                    moduleRows(.storage, titled: true)

                    moduleRows(.software)
                    // Pages of the modules that are on; a module that is off has no row.
                    ForEach(modules.pageGroups) { group in
                        header(group.module.name)
                        ForEach(group.pages.filter { $0.entry.parent == nil || page.module == group.module.id }) { item in
                            row(item.target, item.entry.title, item.entry.symbol ?? item.module.symbol, .teal, trailing: nil,
                                indent: item.depth > 0,
                                selected: { if case let .module(id, entry) = page { return id == item.module.id && (entry.isEmpty ? item.entry.parent == nil && item.id == group.pages.first { $0.entry.parent == nil }?.id : entry == item.entry.id) }; return false }())
                                .padding(.leading, CGFloat(max(0, item.depth - 1)) * 14)
                        }
                    }

                    if nativeGroups.contains(where:{$0.location == .agents}) {
                        header(tr("AI Agent Diagnostics"))
                        moduleRows(.agents)
                    }
                }
                .padding(.bottom, 8)
            }
            // Rows scrolling under the footer fade out instead of being cut in half.
            .mask(VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
            })
            // The selected row is never left half-faded under the footer (Smart Check, sub-pages).
            .onAppear { DispatchQueue.main.async { scroller.scrollTo(page) } }
            .onChange(of: page) { p in
                DispatchQueue.main.async { withAnimation(Theme.standard.unlessReduced(reduceMotion)) { scroller.scrollTo(p) } }
            }
            }
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 14)
            VStack(spacing: 1) {
                moduleRows(.footer)
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
            .foregroundStyle(Theme.textTertiary).padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }

    /// One place in the sidebar. Icons stay grey so the list reads as one column; the selected
    /// row's icon takes its color, and the selection slides from row to row.
    func row(_ target: MainPage, _ title: String, _ symbol: String, _ color: Color, trailing: String?,
             trailingColor: Color? = nil, badge: Int = 0, indent: Bool = false, selected: Bool? = nil,activate:(@MainActor ()->Void)? = nil) -> some View {
        let on = selected ?? (page == target)
        return Button { if let activate {activate()}else{page = target} } label: {
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
            .padding(.horizontal, 10).frame(height: indent ? 25 : 28)
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
        .background(shortcut(target,activate:activate))
        .padding(.horizontal, 8)
        // Scrolled to with room above and below, so the row clears the footer's fade.
        .background(Color.clear.frame(height: (indent ? 26 : 30) + 40).id(target))
    }
    @ViewBuilder func shortcut(_ target: MainPage,activate:(@MainActor ()->Void)? = nil) -> some View {
        if modules.shows(target), let value = modules.navigationKey(target), let character = value.first {
            key(KeyEquivalent(character), target,activate:activate)
        } else { coreShortcut(target) }
    }
    @ViewBuilder func coreShortcut(_ target: MainPage) -> some View {
        switch target {
        case .settings: key(",", target)
        default: EmptyView()
        }
    }

    func key(_ key: KeyEquivalent, _ target: MainPage,activate:(@MainActor ()->Void)? = nil) -> some View {
        Button("") { if let activate {activate()}else{page = target} }.keyboardShortcut(key, modifiers: .command)
            .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }

}

// MARK: - Sensors

/// Every sensor, one inspector panel per group with its hottest reading in the header; power,
/// voltage and current after.
