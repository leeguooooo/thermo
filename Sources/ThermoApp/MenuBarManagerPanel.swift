import AppKit
import MenuBarCore
import SwiftUI
import ThermoL10n
import UniformTypeIdentifiers

@MainActor final class MenuBarManagerPanel: NSWindowController, NSWindowDelegate {
    static let shared = MenuBarManagerPanel(model: .shared)
    private let model: MenuBarManager
    init(model: MenuBarManager) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = tr("Manage menu bar")
        window.minSize = NSSize(width: 840, height: 620)
        window.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: MenuBarManagerView(model: model).preferredColorScheme(.dark))
        content.sizingOptions = []
        window.contentView = content
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func show() {
        (NSApp.delegate as? AppDelegate)?.closeMenuPanel()
        model.setPanelOpen(true)
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { model.setPanelOpen(false) }
}

struct MenuBarManagerView: View {
    @ObservedObject var model: MenuBarManager
    @State private var query = ""
    private var filtered: [ManagedMenuBarApp] {
        model.apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(tr("Manage menu bar"), systemImage: "menubar.rectangle").font(Theme.pageTitle)
                Spacer()
                Button(tr("Restore all icons")) { model.restoreAll() }
                    .accessibilityIdentifier("menubar.restoreAll")
            }
            Text(tr("Drag apps into Visible, Hidden or Always hidden. All menu bar icons from one app move together; use ⌘-drag in the menu bar to change their physical order."))
                .font(Theme.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Toggle(tr("Enable menu bar management (experimental)"), isOn: Binding(get: { model.enabled }, set: model.setEnabled))
                    .disabled(!model.canEdit).accessibilityIdentifier("menubar.enabled")
                Text(tr("On macOS 27 this uses a private system interface. Some system icons, including Focus, may disappear while items are hidden. Restore all icons ends the session."))
                    .font(Theme.secondary).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                Text(tr("Some apps may stay hidden even when assigned to Visible. Restore all icons if an app is missing."))
                    .font(Theme.secondary).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true)
            }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
            if !model.available {
                Label(tr("Menu bar management currently requires macOS 27 and its native visibility interface."), systemImage: "info.circle")
                    .font(Theme.secondary).foregroundStyle(Theme.caution)
            }
            if !model.trusted {
                HStack {
                    Text(tr("Accessibility access is required to discover menu bar apps.")).font(Theme.secondary)
                    Spacer()
                    Button(tr("Open Accessibility settings")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
            if let error = model.error {
                Text(error).font(Theme.secondary).foregroundStyle(Theme.caution).textSelection(.enabled)
                    .accessibilityIdentifier("menubar.error")
            }
            if !model.settingsReadable {
                Button(tr("Reset section settings and keep a backup")) { model.resetUnreadableSettings() }
            }
            HStack {
                Button(tr("Collapse groups")) { model.setReveal(.collapsed) }
                    .disabled(!model.enabled || !model.hasHiddenAssignments)
                    .accessibilityIdentifier("menubar.collapse")
                Button(tr("Show hidden group")) { model.setReveal(.hidden) }
                    .disabled(!model.enabled).accessibilityIdentifier("menubar.showHidden")
                Spacer()
                Text(status).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
            }
            HStack {
                TextField(tr("Search menu bar apps"), text: $query).textFieldStyle(.roundedBorder)
                if model.loading { ProgressView().controlSize(.small) }
                Button(tr("Refresh")) { model.refresh() }.disabled(model.loading)
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(MenuBarSection.allCases, id: \.self) { section in
                    MenuBarDropColumn(model: model, section: section,
                                      apps: filtered.filter { model.sections[$0.id] == section })
                }
            }
            Text(tr("Clock, Control Center and other Apple system items are managed by macOS. App icons shown here are not live menu bar previews."))
                .font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(minWidth: 792, minHeight: 552)
        .background(Theme.canvas).foregroundStyle(Theme.textPrimary)
    }
    private var status: String {
        switch model.state {
        case .visible: return tr("All groups revealed")
        case .applying: return tr("Applying visibility…")
        case .applied: return tr("Visibility request accepted by macOS")
        case .failed: return tr("Visibility needs recovery")
        }
    }
}

private let menuBarAppDragType = UTType(exportedAs: MenuBarDragPayload.typeIdentifier, conformingTo: .data)

private struct MenuBarDropColumn: View {
    @ObservedObject var model: MenuBarManager
    let section: MenuBarSection
    let apps: [ManagedMenuBarApp]
    @State private var targeted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(section.label).font(Theme.heading)
                Spacer()
                Text(String(apps.count)).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(apps) { app in MenuBarDragCard(model: model, app: app) }
                    if apps.isEmpty {
                        Text(tr("Drop apps here")).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 100)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(targeted ? Theme.accent.opacity(0.14) : Theme.surface,
                    in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(targeted ? Theme.accent : Theme.border, lineWidth: targeted ? 2 : 1))
        .contentShape(Rectangle())
        .accessibilityIdentifier("menubar.group." + section.rawValue)
        .onDrop(of: [menuBarAppDragType], delegate: MenuBarSectionDrop(model: model, section: section, targeted: $targeted))
    }
}

private struct MenuBarDragCard: View {
    @ObservedObject var model: MenuBarManager
    let app: ManagedMenuBarApp
    var body: some View {
        HStack(spacing: 6) {
            if model.canEdit && model.isAssignable(app.id) {
                content.onDrag {
                    let provider = NSItemProvider()
                    if let data = model.dragData(for: app.id) {
                        provider.registerDataRepresentation(forTypeIdentifier: MenuBarDragPayload.typeIdentifier, visibility: .ownProcess) { done in
                            done(data, nil); return nil
                        }
                    }
                    provider.suggestedName = app.name
                    return provider
                }
            } else { content }
            if model.isAssignable(app.id) {
                Menu {
                    ForEach(MenuBarSection.allCases, id: \.self) { section in
                        Button(section.label) { model.assign(app.id, to: section) }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 14, height: 20) }
                    .menuStyle(.borderlessButton).frame(width: 18).disabled(!model.canEdit)
                    .accessibilityLabel(tr("Move %1$@ to a group", app.name))
            }
        }
        .padding(8).background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
        .accessibilityIdentifier("menubar.app." + app.id)
    }
    private var content: some View {
        HStack(spacing: 10) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24)
            } else { Image(systemName: "app.dashed").frame(width: 24, height: 24) }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(Theme.rowTitle).lineLimit(1)
                Text(app.id + (model.isRunning(app.id) ? "" : " · " + tr("Not running")))
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Image(systemName: model.isAssignable(app.id) ? "line.3.horizontal" : "lock")
                .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity).contentShape(Rectangle())
        .help(model.isAssignable(app.id) ? tr("Drag %1$@ to another group", app.name) : tr("Managed by macOS"))
    }
}

private struct MenuBarSectionDrop: DropDelegate {
    let model: MenuBarManager
    let section: MenuBarSection
    @Binding var targeted: Bool
    func validateDrop(info: DropInfo) -> Bool { model.canEdit && info.hasItemsConforming(to: [menuBarAppDragType]) }
    func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard model.canEdit, let provider = info.itemProviders(for: [menuBarAppDragType]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: MenuBarDragPayload.typeIdentifier) { data, _ in
            guard let data else { return }
            Task { @MainActor in model.acceptDrop(data, into: section) }
        }
        return true
    }
}

private extension MenuBarSection {
    var label: String {
        switch self {
        case .visible: return tr("Visible")
        case .hidden: return tr("Hidden")
        case .alwaysHidden: return tr("Always hidden")
        }
    }
}
