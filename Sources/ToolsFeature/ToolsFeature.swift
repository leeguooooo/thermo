import AgentCore
import AppKit
import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoL10n
import ToolsControlAPI

/// What the tools need from the host: opening a tool's panel in the main window and installing the
/// system helper. Set once by registration; nothing else of the shell is reachable from here.
enum ToolsHost {
    // Written once while the app assembles its features, before any tool runs.
    nonisolated(unsafe) static var show: @MainActor @Sendable (ShellTool) -> Void = { _ in }
    nonisolated(unsafe) static var helper: @MainActor @Sendable () -> Void = {}
    @MainActor static func showPanel(_ tool: ShellTool) { show(tool) }
    @MainActor static func installHelper() { helper() }
}

package enum ToolsFeature {
    /// One definition per tool, in the order the settings page lists them.
    package static func registrations(showPanel: @escaping @MainActor @Sendable (ShellTool) -> Void,
                                      installHelper: @escaping @MainActor @Sendable () -> Void) -> [NativeFeatureDefinition] {
        ToolsHost.show = showPanel; ToolsHost.helper = installHelper
        return [ShellTool.cleanScreen, .keepAwake, .focus, .lowLatency, .batteryCare].map(definition)
    }
    package static func definition(_ tool: ShellTool) -> NativeFeatureDefinition { definition(tool, runtime: { .live }) }
    static func definition(_ tool: ShellTool, runtime: @escaping @MainActor @Sendable () -> ToolRuntime) -> NativeFeatureDefinition {
        .init(manifest: tool.manifest, runsInBackground: true, makeSession: { ToolSession(tool: tool, availability: $0, runtime: runtime()) })
    }
    /// One access per store, so an app control mutation in progress is seen by the next request.
    @MainActor package static func makeAccess(_ store: NativeFeatureStore) -> any ToolsApplicationAccess {
        if let cached = access, cached.store === store { return cached }
        let made = ToolsAccess(store: store); access = made; return made
    }
    @MainActor private static var access: ToolsAccess?
}

/// Every tool keeps its one shared model, as before it was a module; a session only decides
/// whether the tool is reachable and starts or ends its background work.
@MainActor final class ToolSession: NativeFeatureSession {
    let tool: ShellTool
    private let availability: FeatureAvailability
    private let runtime: ToolRuntime
    init(tool: ShellTool, availability: FeatureAvailability, runtime: ToolRuntime) {
        self.tool = tool; self.availability = availability; self.runtime = runtime
    }
    func retireVisibility() {}
    func quitBlocker() -> NativeFeatureBlocker? { nil }
    func ui(_ surface: NativeUISurface, navigation: NativeNavigation) -> AnyView? {
        guard availability.acceptsWork else { return nil }
        switch surface {
        case let .inlineSettings(ref) where ref == tool.options: return runtime.row(tool)
        case let .renderPreview(ref) where ref == tool.options: return runtime.panel(tool)
        default: return nil
        }
    }
    func page(_ route: NativeFeatureRoute, navigation: NativeNavigation) -> AnyView? { nil }
    var status: NativeFeatureStatus { .init(modelLoaded: true, sampling: runtime.active(tool), snapshotReady: true) }
    func start() { guard availability.acceptsWork else { return }; runtime.start(tool) }
    func prepareStop() throws -> NativeFeatureDrain {
        let finish = try runtime.stop(tool)
        return .init(finish: finish)
    }
}

/// The real models behind each tool. Tests replace it to observe start and stop.
@MainActor struct ToolRuntime {
    var row: (ShellTool) -> AnyView
    var panel: (ShellTool) -> AnyView
    var active: (ShellTool) -> Bool
    var start: (ShellTool) -> Void
    /// Ends the tool's running work. Throws when it cannot end yet; the returned drain waits for
    /// hardware changes to be restored and confirmed.
    var stop: (ShellTool) throws -> (() async -> Void)

    /// The focus timer may start a round when Thermo launches; switching it back on later must not.
    private static var launched = false

    static let live = ToolRuntime(row: { tool in
        switch tool {
        case .cleanScreen: return AnyView(CleanScreenButton())
        case .keepAwake: return AnyView(IdleAwakeButton())
        case .focus: return AnyView(FocusButton())
        case .lowLatency: return AnyView(AWDLButton())
        case .batteryCare: return AnyView(BatteryCareButton())
        }
    }, panel: { tool in
        switch tool {
        case .cleanScreen: return AnyView(CleanScreenSetupView(model: .shared))
        case .keepAwake: return AnyView(IdleAwakePanel(model: .shared))
        case .focus: return AnyView(FocusPanel(model: .shared))
        case .lowLatency: return AnyView(AWDLPanel(model: .shared))
        case .batteryCare: return AnyView(BatteryCarePanel(model: .shared))
        }
    }, active: activeLive, start: { tool in
        switch tool {
        case .cleanScreen: CleanScreenShortcutModel.enableLive()
        case .batteryCare: BatteryCareModel.shared.restoreSavedPreference()
        case .focus:
            FocusStatusItem.shared.start()
            if !launched { launched = true; FocusTimerModel.shared.launch() }
        case .keepAwake, .lowLatency: break
        }
    }, stop: { tool in
        switch tool {
        case .cleanScreen:
            CleanScreenModel.shared.stop()
            CleanScreenShortcutModel.shared.deactivate()
            CleanScreenSetupWindow.close()
            return {}
        case .keepAwake:
            let model = IdleAwakeModel.shared
            if model.canStop { model.stop() }
            return {}
        case .focus:
            FocusTimerModel.shared.stop()
            FocusStatusItem.shared.stop()
            return {}
        case .lowLatency:
            let model = AWDLModel.shared
            guard !model.quitRequested else { throw NativeFeatureBusy(tr("Wait for Thermo to restore AWDL before switching this feature off.")) }
            return { await model.releaseForSwitchOff() }
        case .batteryCare:
            let model = BatteryCareModel.shared
            guard !model.quitRequested else { throw NativeFeatureBusy(tr("Wait for normal charging to be restored before switching this feature off.")) }
            return { await model.releaseForSwitchOff() }
        }
    })

    static func activeLive(_ tool: ShellTool) -> Bool {
        switch tool {
        case .cleanScreen: return CleanScreenModel.shared.active
        case .keepAwake: return IdleAwakeModel.shared.state.phase == .active
        case .focus: return FocusTimerModel.shared.phase.isActive
        case .lowLatency: return AWDLModel.shared.state?.phase == .active
        case .batteryCare: return BatteryCareModel.shared.state?.ownedByCaller == true
        }
    }
}

/// The shell's view of the tools. A tool that is switched off has no menu and is never active.
@MainActor final class ToolsAccess: ToolsApplicationAccess {
    let store: NativeFeatureStore
    private let control: ToolsControl
    init(store: NativeFeatureStore, control: ToolsControl? = nil) {
        self.store = store
        self.control = control ?? ToolsControl(enabled: { [weak store] tool in store?.canAdmitUIEntryOwner(tool.options) == true })
    }
    private func on(_ tool: ShellTool) -> Bool { store.canAdmitUIEntryOwner(tool.options) }
    func isActive(_ tool: ShellTool) -> Bool { on(tool) && ToolRuntime.activeLive(tool) }
    func menu(_ tool: ShellTool) -> [NativeMenuNode] {
        guard on(tool) else { return [] }
        switch tool {
        case .keepAwake: return KeepAwakeMenu.nodes()
        case .focus: return FocusMenu.nodes()
        case .cleanScreen, .lowLatency, .batteryCare:
            return [.action(.init(title: tr(tool.manifest.name), symbol: tool.manifest.symbol) { ToolsHost.showPanel(tool) })]
        }
    }
    var keepAwakeMarker: String {
        guard on(.keepAwake) else { return "" }
        let awake = IdleAwakeModel.shared.state
        return awake.phase == .active ? "☕︎" : awake.phase == .ending ? "☕︎?" : awake.requested ? "☕︎⏸" : ""
    }
    func observeKeepAwake(_ change: @escaping @MainActor () -> Void) { IdleAwakeModel.shared.onStateChange = change }
    func handles(_ action: String) -> Bool { ToolsControl.handles(action) }
    func handle(_ request: AppControlRequest) async -> AppControlResponse { await control.handle(request) }
    var statusValues: [String: String] { control.statusValues() }
    func requestQuit() -> Bool { BatteryCareModel.shared.requestQuit() || AWDLModel.shared.requestQuit() }
}

/// Keep awake: the common lengths right in the menu, everything else in its panel.
@MainActor enum KeepAwakeMenu {
    static func nodes() -> [NativeMenuNode] { nodes(.shared) }
    static func nodes(_ model: IdleAwakeModel) -> [NativeMenuNode] {
        var items: [NativeMenuNode] = []
        if model.canStop {
            items += [.action(.init(title: tr("Stop keeping awake"), symbol: "stop.circle") { model.stop() }), .separator]
        }
        for (title, seconds) in [(tr("30 minutes"), 1800.0), (tr("1 hour"), 3600.0), (tr("2 hours"), 7200.0)] {
            items.append(.action(.init(title: title, enabled: model.canStart) { model.start(mode: .both, seconds: seconds) }))
        }
        items.append(.action(.init(title: tr("Until I turn it off"), enabled: model.canStart) { model.start(mode: .both, seconds: nil) }))
        items += [.separator, .action(.init(title: tr("Options…"), symbol: "slider.horizontal.3") { ToolsHost.showPanel(.keepAwake) })]
        return items
    }
}

/// The focus timer's actions for the current phase. The status menu and the countdown item share them.
@MainActor enum FocusMenu {
    static func nodes() -> [NativeMenuNode] { nodes(.shared) }
    static func nodes(_ model: FocusTimerModel) -> [NativeMenuNode] {
        FocusAction.available(in: model.phase).map { action in .action(.init(title: action.title) { action.run(model) }) }
            + [.separator, .action(.init(title: tr("Focus timer options…"), symbol: "slider.horizontal.3") { ToolsHost.showPanel(.focus) })]
    }
    static func make() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for node in nodes() {
            switch node {
            case let .action(action):
                let item = MenuAction(action)
                if let symbol = action.symbol {
                    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); image?.isTemplate = true; item.image = image
                }
                menu.addItem(item)
            case .separator: menu.addItem(.separator())
            case .submenu: break
            }
        }
        return menu
    }
    @MainActor private final class MenuAction: NSMenuItem {
        private let run: NativeMenuAction
        init(_ action: NativeMenuAction) {
            run = action
            super.init(title: action.title, action: #selector(fire), keyEquivalent: "")
            target = self; isEnabled = action.enabled
        }
        required init(coder: NSCoder) { fatalError("init(coder:) is not used") }
        @objc private func fire() { MainActor.assumeIsolated { run.perform() } }
    }
}
