import AppKit
import ExtensionKit
import ModuleHost
import ModuleKit
import SwiftUI
import ThermoL10n

/// The app's one module manager and what the UI is built from: the pages of the modules that are on.
/// Which modules are on is remembered per module; a new module starts as its manifest says.
@MainActor final class ModuleCenter: ObservableObject {
    static let shared = ModuleCenter()

    struct Page: Identifiable, Equatable {
        var module: ModuleManifest
        var entry: ModuleManifest.Entry
        var id: String { module.id + ":" + entry.id }
        var target: MainPage { .module(module.id, entry.id) }
    }

    let manager: ModuleManager
    private let defaults: UserDefaults
    @Published private(set) var statuses: [ModuleManager.Status] = []
    /// False until the modules inside the app have been read.
    @Published private(set) var loaded = false
    private var started = false

    init(manager: ModuleManager? = nil, defaults: UserDefaults = .standard) {
        self.manager = manager ?? ModuleManager(); self.defaults = defaults
    }

    static func key(_ id: String) -> String { "module.enabled." + id }

    /// Reads the modules and starts the ones that are on and meant to run in the background.
    func start() {
        guard !started else { return }
        started = true
        manager.onChange = { [weak self] _ in self?.refresh() }
        manager.kernel = { ModuleKernel.make(for: $0) }
        Task { @MainActor in
            let defaults = self.defaults
            await manager.load { defaults.object(forKey: Self.key($0.id)) as? Bool ?? $0.enabledByDefault }
            for problem in manager.problems { NSLog("Thermo module refused: %@", problem) }
            loaded = true
            refresh()
        }
    }

    private func refresh() {
        let now = manager.modules
        if now != statuses { statuses = now }
    }

    /// The sidebar's module rows: page entries of the modules that are on, in bundle order.
    var pages: [Page] {
        statuses.filter(\.enabled).flatMap { status in
            let shown = status.manifest.localized(L10n.current.rawValue)
            return shown.entries.filter { $0.kind == .page }.map { Page(module: shown, entry: $0) }
        }
    }

    /// The page `--page module:<id>[:<entry>]` names, if that module is on.
    func page(module: String, entry: String) -> Page? {
        pages.first { $0.module.id == module && (entry.isEmpty || $0.entry.id == entry) }
    }

    func setEnabled(_ id: String, _ on: Bool) {
        defaults.set(on, forKey: Self.key(id))
        manager.setEnabled(id, on)
        // A module that was switched off is in no entry point, the open page included.
        if !on, case let .module(shown, _) = MainWindow.state.page, shown == id { MainWindow.state.page = .overview }
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
        } else {
            VStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 36, weight: .light)).foregroundStyle(Theme.textSecondary)
                Text(tr("This feature is switched off.")).font(Theme.heading)
                Text(tr("Switch it on in Settings to use it.")).font(Theme.body).foregroundStyle(Theme.textSecondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
        ForEach(Array(center.statuses.enumerated()), id: \.element.manifest.id) { index, status in
            if index > 0 { InspectorDivider(inset: 46) }
            HStack(spacing: Theme.Space.m) {
                Image(systemName: status.manifest.symbol).frame(width: 22).foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.manifest.localized(L10n.current.rawValue).name).font(Theme.body)
                    if !status.manifest.summary.isEmpty {
                        Text(status.manifest.localized(L10n.current.rawValue).summary).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                Button(tr("Activity")) { activity = status.manifest.localized(L10n.current.rawValue) }.buttonStyle(PillButtonStyle()).controlSize(.small).fixedSize()
                Toggle("", isOn: Binding(get: { status.enabled }, set: { center.setEnabled(status.manifest.id, $0) }))
                    .labelsHidden().toggleStyle(.switch).accessibilityLabel(status.manifest.name)
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
