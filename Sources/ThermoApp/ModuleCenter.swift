import AppKit
import ExtensionKit
import ModuleHost
import ModuleKit
import SwiftUI
import ThermoL10n

/// The app's one module manager and what the UI is built from: the pages of the modules that are on.
/// Which modules are on is remembered per module; a new module starts as its manifest says.
@MainActor final class ModuleCenter: ObservableObject {
    static let shared = ModuleCenter(updatesAppMenu: true)

    struct Page: Identifiable, Equatable {
        var module: ModuleManifest
        var entry: ModuleManifest.Entry
        var id: String { module.id + ":" + entry.id }
        var target: MainPage { .module(module.id, entry.id) }
        var depth: Int { module.depth(of: entry.id) }
    }

    let manager: ModuleManager
    private let defaults: UserDefaults
    private let updatesAppMenu: Bool
    private let prepareBuiltinStop: @MainActor (String) throws -> BuiltinModules.FinishStop?
    @Published private(set) var changing = Set<String>()
    @Published private(set) var switchIssues: [String: String] = [:]
    @Published private(set) var statuses: [ModuleManager.Status] = []
    /// Bumped when a built-in feature is switched, so views that show its entries update.
    @Published private(set) var revision = 0
    /// False until the modules inside the app have been read.
    @Published private(set) var loaded = false
    private var started = false

    init(manager: ModuleManager? = nil, defaults: UserDefaults = .standard,
         prepareBuiltinStop: @escaping @MainActor (String) throws -> BuiltinModules.FinishStop? = BuiltinModules.prepareStop,
         updatesAppMenu: Bool = false) {
        self.manager = manager ?? ModuleManager(); self.defaults = defaults
        self.prepareBuiltinStop = prepareBuiltinStop
        self.updatesAppMenu = updatesAppMenu
    }

    static func key(_ id: String) -> String { ModulePreferences.key(id) }

    /// The person's choice for a module, or the manifest's default when they never chose.
    /// `bool(forKey:)` also reads a value given on the command line (`-module.enabled.<id> NO`).
    static func stored(_ manifest: ModuleManifest, in defaults: UserDefaults) -> Bool {
        ModulePreferences.isEnabled(manifest, in: defaults)
    }

    /// Reads the modules and starts the ones that are on and meant to run in the background.
    func start() {
        guard !started else { return }
        started = true
        manager.onChange = { [weak self] _ in self?.refresh() }
        manager.kernel = { ModuleKernel.make(for: $0) }
        Task { @MainActor in
            let defaults = self.defaults
            await manager.load { Self.stored($0, in: defaults) }
            for problem in manager.problems { NSLog("Thermo module refused: %@", problem) }
            loaded = true
            refresh()
        }
    }

    private func refresh() {
        let now = manager.modules
        if now != statuses {
            statuses = now
            if updatesAppMenu, NSApp != nil { installStandardMenus(center: self) }
        }
    }

    /// The sidebar's module rows: page entries of the modules that are on, in bundle order.
    var pages: [Page] {
        statuses.filter(\.enabled).flatMap { status in
            let shown = status.manifest.localized(L10n.current.rawValue)
            return shown.entries.filter { $0.kind == .page }.map { Page(module: shown, entry: $0) }
        }
    }

    struct PageGroup: Identifiable {
        let module: ModuleManifest
        let pages: [Page]
        var id: String { module.id }
    }
    var pageGroups: [PageGroup] {
        statuses.filter(\.enabled).compactMap { status in
            let manifest = status.manifest.localized(L10n.current.rawValue)
            let entries = pages.filter { $0.module.id == manifest.id }
            return entries.isEmpty ? nil : .init(module: manifest, pages: entries)
        }
    }

    /// The page `--page module:<id>[:<entry>]` names, if that module is on.
    func page(module: String, entry: String) -> Page? {
        pages.first { $0.module.id == module && (entry.isEmpty ? $0.entry.parent == nil : $0.entry.id == entry) }
    }

    /// Whether a module is on. A built-in feature is known at once; a module in its own process once it has been read.
    func isOn(_ id: String) -> Bool {
        if let builtin = BuiltinModules.manifest(id) { return Self.stored(builtin, in: defaults) }
        return statuses.first { $0.manifest.id == id }?.enabled ?? false
    }

    /// Whether anything may lead to `page`: always for Thermo's own pages, otherwise only while the module is on.
    func shows(_ page: MainPage) -> Bool {
        guard let module = page.module else { return true }
        return BuiltinModules.manifest(module) == nil ? true : isOn(module)
    }

    /// Every module with its switch, built-in features first.
    var switches: [(manifest: ModuleManifest, enabled: Bool, builtin: Bool)] {
        BuiltinModules.all.map { ($0, isOn($0.id), true) } + statuses.map { ($0.manifest, $0.enabled, false) }
    }

    struct NavigationPage: Identifiable {
        let module: ModuleManifest
        let entry: ModuleManifest.Entry
        let target: MainPage
        let builtin: Bool
        var id: String { module.id + ":" + entry.id }
        var title: String { builtin ? tr(entry.title) : entry.title }
        var moduleTitle: String { builtin ? tr(module.name) : module.name }
        var navigationTitle: String {
            module.entries.filter { $0.kind == .page && $0.parent == nil }.count == 1 && entry.parent == nil ? moduleTitle : title
        }
        var symbol: String { entry.symbol ?? module.symbol }
    }
    var activeManifests: [ModuleManifest] {
        BuiltinModules.all.filter { isOn($0.id) } + statuses.filter(\.enabled).map(\.manifest)
    }
    var navigationConflicts: [ModuleNavigation.Conflict] { ModuleNavigation.conflicts(activeManifests) }
    func navigationIssue(_ id: String) -> String? {
        guard let conflict = navigationConflicts.first(where: { $0.module == id }) else { return nil }
        guard let owner = conflict.owner else {
            return tr("Command-%1$@ belongs to Thermo's built-in navigation.", conflict.key)
        }
        let name = BuiltinModules.manifest(owner).map { tr($0.name) }
            ?? statuses.first { $0.manifest.id == owner }?.manifest.localized(L10n.current.rawValue).name ?? owner
        return tr("Command-%1$@ is already used by %2$@. Switch that feature off first.", conflict.key, name)
    }
    var navigationPages: [NavigationPage] {
        let native = BuiltinModules.implementations.filter { isOn($0.manifest.id) }.flatMap { owner in
            owner.manifest.entries.compactMap { entry -> NavigationPage? in
                guard entry.kind == .page, let scene = entry.scene, let target = owner.target(scene) else { return nil }
                return .init(module: owner.manifest, entry: entry, target: target, builtin: true)
            }
        }
        return native + pages.map { .init(module: $0.module, entry: $0.entry, target: $0.target, builtin: false) }
    }
    var rootPages: [NavigationPage] { navigationPages.filter { $0.entry.parent == nil } }
    func navigationKey(_ target: MainPage) -> String? {
        let identity: String
        if let native = BuiltinModules.page(target) { identity = native.module.id + ":" + native.entry.id }
        else if case let .module(id, entry) = target, let page = page(module: id, entry: entry) { identity = page.id }
        else { return nil }
        guard let page = navigationPages.first(where: { $0.id == identity }), let key = page.entry.navigationKey,
              !navigationConflicts.contains(where: { $0.module == page.module.id && $0.key == key }) else { return nil }
        return key
    }
    func rootPage(_ module: String) -> MainPage? {
        rootPages.first { $0.module.id == module }?.target
    }
    func legacyMenuPage(_ key: String) -> NavigationPage? {
        guard let old = BuiltinModules.legacyMenuEntry(key), isOn(old.module.id), let target = old.target else { return nil }
        return .init(module: old.module, entry: old.entry, target: target, builtin: true)
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard !changing.contains(id) else { return }
        var finish: BuiltinModules.FinishStop?
        if !on, BuiltinModules.manifest(id) != nil {
            do { finish = try prepareBuiltinStop(id) }
            catch { switchIssues[id] = String(describing: error); return }
        }
        switchIssues[id] = nil
        if finish != nil { changing.insert(id) }
        defaults.set(on, forKey: Self.key(id))
        if BuiltinModules.manifest(id) != nil {
            revision += 1
            // The View menu and its shortcuts list pages too.
            if updatesAppMenu, NSApp != nil { installStandardMenus(center: self) }
        } else { manager.setEnabled(id, on) }
        // A module that was switched off is in no entry point, the open page included.
        if !on, MainWindow.state.page.module == id { MainWindow.state.page = .overview }
        if let finish {
            Task { @MainActor in
                await finish()
                changing.remove(id)
            }
        }
    }
}

/// A module's page: drawn by the module in its own process, embedded here. The module runs while
/// the page is shown and may be stopped once it is left.
struct ModulePageView: View {
    @ObservedObject var center: ModuleCenter
    let module: String
    let entry: String

    var body: some View {
        if !center.loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let page = center.page(module: module, entry: entry), let scene = page.entry.scene {
            ModuleSceneView(manager: center.manager, module: module, scene: scene).id(page.id)
                .padding(.top, 28)   // Clear of the window's title bar buttons.
        } else { ModuleOffView() }
    }
}

/// What a page shows when something still leads to a feature that is switched off.
struct ModuleOffView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension").font(.system(size: 36, weight: .light)).foregroundStyle(Theme.textSecondary)
            Text(tr("This feature is switched off.")).font(Theme.heading)
            Text(tr("Switch it on in Settings to use it.")).font(Theme.body).foregroundStyle(Theme.textSecondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ModuleSceneView: NSViewControllerRepresentable {
    let manager: ModuleManager
    let module: String
    let scene: String

    final class Coordinator { var scene: ModuleManager.Scene? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSViewController(context: Context) -> NSViewController {
        guard let attached = try? manager.attach(module, scene: scene) else { return NSViewController() }
        context.coordinator.scene = attached
        return attached.controller
    }
    func updateNSViewController(_ controller: NSViewController, context: Context) {}
    static func dismantleNSViewController(_ controller: NSViewController, coordinator: Coordinator) {
        // SwiftUI calls this on the main thread.
        MainActor.assumeIsolated {
            if let scene = coordinator.scene { ModuleCenter.shared.manager.detach(scene); coordinator.scene = nil }
        }
    }
}

/// Settings: one switch per module inside the app. Not shown when there are none.
struct ModuleSwitches: View {
    @ObservedObject var center: ModuleCenter
    @State private var activity: ModuleManifest?
    var body: some View {
        ForEach(Array(center.switches.enumerated()), id: \.element.manifest.id) { index, status in
            if index > 0 { InspectorDivider(inset: 46) }
            HStack(spacing: Theme.Space.m) {
                Image(systemName: status.manifest.symbol).frame(width: 22).foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    // Built-in features are worded in the app's own string table.
                    Text(status.builtin ? tr(status.manifest.name) : status.manifest.localized(L10n.current.rawValue).name).font(Theme.body)
                    if !status.manifest.summary.isEmpty {
                        Text(status.builtin ? tr(status.manifest.summary) : status.manifest.localized(L10n.current.rawValue).summary).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                    }
                    if let issue = center.switchIssues[status.manifest.id] ?? center.navigationIssue(status.manifest.id) {
                        Text(issue).font(Theme.secondary).foregroundStyle(Theme.caution)
                    }
                    if center.changing.contains(status.manifest.id) {
                        Text(tr("stopping…")).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                // Only a module in its own process goes through the kernel and has a record of it.
                if !status.builtin {
                    Button(tr("Activity")) { activity = status.manifest.localized(L10n.current.rawValue) }.buttonStyle(PillButtonStyle()).controlSize(.small).fixedSize()
                }
                Toggle("", isOn: Binding(get: { status.enabled }, set: { center.setEnabled(status.manifest.id, $0) }))
                    .labelsHidden().toggleStyle(.switch).accessibilityLabel(status.manifest.name)
                    .disabled(center.changing.contains(status.manifest.id))
            }.padding(.horizontal, Theme.Space.m).padding(.vertical, 8)
        }
        .sheet(item: Binding(get: { activity.map(ActivityTarget.init) }, set: { activity = $0?.manifest })) { target in
            ModuleActivityView(manifest: target.manifest) { activity = nil }
        }
    }
}

private struct ActivityTarget: Identifiable {
    let manifest: ModuleManifest
    var id: String { manifest.id }
}


struct ModuleSettingsControls: View {
    @ObservedObject var center: ModuleCenter
    let models: AppModels
    var body: some View {
        ForEach(BuiltinModules.implementations.indices, id: \.self) { index in
            let owner = BuiltinModules.implementations[index]
            if center.isOn(owner.manifest.id) {
                ForEach(owner.manifest.entries.filter { $0.kind == .settingsItem }, id: \.id) { entry in
                    InspectorDivider(inset: 46)
                    owner.settings(entry, models: models)
                }
            }
        }
        ForEach(center.statuses.filter(\.enabled), id: \.manifest.id) { status in
            ForEach(status.manifest.entries.filter { $0.kind == .settingsItem }, id: \.id) { entry in
                if let scene = entry.scene {
                    InspectorDivider(inset: 46)
                    ModuleSceneView(manager: center.manager, module: status.manifest.id, scene: scene)
                        .frame(minHeight: 180, maxHeight: 360)
                }
            }
        }
    }
}

struct ModulePanelLinks: View {
    @ObservedObject private var center = ModuleCenter.shared
    var body: some View {
        let roots = center.rootPages
        ForEach(Array(roots.prefix(2))) { item in
            Button { MainWindow.show(item.target) } label: { Image(systemName: item.symbol).frame(width: 22) }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary).help(item.navigationTitle)
                .accessibilityLabel(item.navigationTitle)
        }
        if roots.count > 2 {
            Menu {
                ForEach(Array(roots.dropFirst(2))) { item in
                    Button(item.navigationTitle) { MainWindow.show(item.target) }
                }
            } label: { Image(systemName: "puzzlepiece.extension").frame(width: 22) }
            .menuStyle(.borderlessButton).fixedSize().help(tr("Features"))
        }
    }
}
