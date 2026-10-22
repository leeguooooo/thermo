import AppKit
import SwiftUI
import ThermoL10n
import ToolExtensionCore

/// Native capabilities are provided by modules, not by the menu or settings
/// view. Script/third-party providers can implement a separate host adapter.
@MainActor protocol NativeToolExtension: AnyObject {
    var descriptor: ToolExtensionDescriptor { get }
    func activate()
    func deactivate()
    func open()
}

@MainActor private final class MenuBarToolExtension: NativeToolExtension {
    let descriptor = ToolExtensionDescriptor(id: "builtin.menubar", title: "Manage menu bar", symbol: "menubar.rectangle",
        summary: "Assign menu bar apps to groups and restore their visibility.")
    func activate() { MenuBarManager.shared.start() }
    func deactivate() { MenuBarManager.shared.shutdown() }
    func open() { MenuBarManagerPanel.shared.show() }
}

@MainActor final class ToolExtensionHost: ObservableObject {
    static let shared = ToolExtensionHost(store: .init(url: defaultConfigurationURL))
    private static var defaultConfigurationURL: URL {
        if let bundle = Bundle.main.bundleIdentifier, bundle.hasPrefix("dev.thermo.menubarqa.") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("\(bundle)/Extensions/settings.json")
        }
        return ToolExtensionConfigurationStore.defaultURL
    }
    @Published private(set) var configuration = ToolExtensionConfiguration()
    @Published private(set) var error: String?
    @Published private(set) var readable = true
    private let modules: [any NativeToolExtension]
    private let store: ToolExtensionConfigurationStore
    private var activeIDs = Set<String>()
    private var started = false

    init(store: ToolExtensionConfigurationStore = .init(), modules: [any NativeToolExtension]? = nil) {
        self.store = store
        self.modules = modules ?? [MenuBarToolExtension()]
        reload()
    }
    var descriptors: [ToolExtensionDescriptor] { configuration.ordered(modules.map(\.descriptor)) }
    var menuExtensions: [ToolExtensionDescriptor] { readable ? configuration.ordered(modules.map(\.descriptor), menuOnly: true) : [] }
    var configurationURL: URL { store.url }
    func isEnabled(_ id: String) -> Bool {
        guard readable, let descriptor = modules.first(where: { $0.descriptor.id == id })?.descriptor else { return false }
        return configuration.preference(for: descriptor).enabled
    }
    func preference(_ descriptor: ToolExtensionDescriptor) -> ToolExtensionPreference { configuration.preference(for: descriptor) }
    func start() { started = true; reconcile() }
    func shutdown() {
        started = false
        for module in modules where activeIDs.contains(module.descriptor.id) { module.deactivate() }
        activeIDs.removeAll()
    }
    func open(_ id: String) {
        guard isEnabled(id), let module = modules.first(where: { $0.descriptor.id == id }) else { return }
        if !started { start() }
        module.open()
    }
    func reload() {
        do { configuration = try store.read(); readable = true; error = nil }
        catch { readable = false; self.error = error.localizedDescription }
        if started { reconcile() }
    }
    func update(_ descriptor: ToolExtensionDescriptor, preference: ToolExtensionPreference) {
        guard readable else { return }
        var next = configuration; next.extensions[descriptor.id] = preference
        do { try store.write(next); configuration = next; error = nil; if started { reconcile() } }
        catch { self.error = error.localizedDescription }
    }
    func revealConfiguration() {
        do {
            if !FileManager.default.fileExists(atPath: store.url.path) { try store.write(configuration) }
            NSWorkspace.shared.activateFileViewerSelecting([store.url])
        } catch { self.error = error.localizedDescription }
    }
    private func reconcile() {
        for module in modules {
            let id = module.descriptor.id
            if isEnabled(id) {
                if activeIDs.insert(id).inserted { module.activate() }
            } else if activeIDs.remove(id) != nil { module.deactivate() }
        }
    }
}

@MainActor final class ToolExtensionPanel: NSWindowController {
    static let shared = ToolExtensionPanel()
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 440),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = tr("Extensions"); window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 350)
        let content = NSHostingView(rootView: ToolExtensionView(host: .shared).preferredColorScheme(.dark))
        content.sizingOptions = []
        window.contentView = content
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func show() {
        ToolExtensionHost.shared.reload()
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
}

struct ToolExtensionView: View {
    @ObservedObject var host: ToolExtensionHost
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(tr("Extensions"), systemImage: "puzzlepiece.extension").font(Theme.pageTitle)
            Text(tr("Enable tools and choose which appear in the menu. Disabling a native extension stops its work. Menu bar management is the first migrated module; other existing tools have not moved here yet."))
                .font(Theme.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if let error = host.error { Text(error).foregroundStyle(Theme.caution).textSelection(.enabled) }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(host.descriptors) { descriptor in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(tr(descriptor.title), systemImage: descriptor.symbol).font(Theme.heading)
                                Spacer()
                                Toggle(tr("Enabled"), isOn: binding(descriptor, \.enabled)).toggleStyle(.switch).controlSize(.small)
                            }
                            Text(tr(descriptor.summary)).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                            HStack {
                                Toggle(tr("Show in menu"), isOn: binding(descriptor, \.showInMenu))
                                Spacer()
                                Stepper(tr("Order: %1$@", String(host.preference(descriptor).order)), value: binding(descriptor, \.order), in: -100...100)
                                    .frame(width: 140)
                                Button(tr("Open")) { host.open(descriptor.id) }.disabled(!host.isEnabled(descriptor.id))
                            }.font(Theme.secondary)
                            Text(descriptor.id).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        }.padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                        .disabled(!host.readable)
                    }
                }
            }
            HStack {
                Button(tr("Reveal configuration file")) { host.revealConfiguration() }
                Button(tr("Reload configuration")) { host.reload() }
                Spacer()
            }
            Text(tr("Third-party script loading and shared shortcuts are not implemented yet."))
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }.padding(24).background(Theme.canvas).foregroundStyle(Theme.textPrimary)
    }
    private func binding<T>(_ descriptor: ToolExtensionDescriptor, _ key: WritableKeyPath<ToolExtensionPreference, T>) -> Binding<T> {
        Binding(get: { host.preference(descriptor)[keyPath: key] }, set: { value in
            var preference = host.preference(descriptor); preference[keyPath: key] = value
            host.update(descriptor, preference: preference)
        })
    }
}
