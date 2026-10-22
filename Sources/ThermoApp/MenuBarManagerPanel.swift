import AppKit
import MenuBarCore
import SwiftUI
import ThermoL10n

@MainActor final class MenuBarManagerPanel: NSWindowController, NSWindowDelegate {
    static let shared = MenuBarManagerPanel()
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = tr("Manage menu bar")
        window.minSize = NSSize(width: 600, height: 450)
        window.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: MenuBarManagerView(model: .shared).preferredColorScheme(.dark))
        content.sizingOptions = []
        window.contentView = content
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func show() {
        (NSApp.delegate as? AppDelegate)?.closeMenuPanel()
        MenuBarManager.shared.setPanelOpen(true)
        if window?.isVisible != true { window?.center() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { MenuBarManager.shared.setPanelOpen(false) }
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
            Text(tr("Assign apps to Visible, Hidden or Always hidden. All menu bar icons from one app move together; use ⌘-drag in the menu bar to change their physical order."))
                .font(Theme.body).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Toggle(tr("Enable menu bar management (experimental)"), isOn: Binding(get: { model.enabled }, set: model.setEnabled))
                    .disabled(!model.canEdit).accessibilityIdentifier("menubar.enabled")
                Text(tr("On macOS 27 this uses a private system interface. Some system icons, including Focus, may disappear while items are hidden. Restore all icons ends the session."))
                    .font(Theme.secondary).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if filtered.isEmpty {
                        Text(tr("No matching menu bar apps. Allow Accessibility access and refresh. Saved apps remain editable when they are not running."))
                            .font(Theme.body).foregroundStyle(Theme.textSecondary).padding(.vertical, 16)
                    }
                    ForEach(MenuBarSection.allCases, id: \.self) { section in
                        let rows = filtered.filter { model.sections[$0.id] == section }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.label + " (\(rows.count))").font(Theme.heading)
                            ForEach(rows) { app in appRow(app) }
                        }
                    }
                }.padding(.vertical, 4)
            }
            Text(tr("Clock, Control Center and other Apple system items are managed by macOS. App icons shown here are not live menu bar previews."))
                .font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(minWidth: 552, minHeight: 402)
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
    private func appRow(_ app: ManagedMenuBarApp) -> some View {
        HStack(spacing: 10) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
            } else { Image(systemName: "app.dashed").frame(width: 28, height: 28) }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(Theme.rowTitle)
                Text(app.id + (model.isRunning(app.id) ? "" : " · " + tr("Not running")))
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if model.isAssignable(app.id) {
                Picker(tr("Section for %1$@", app.name), selection: Binding(get: { model.sections[app.id] }, set: { model.assign(app.id, to: $0) })) {
                    ForEach(MenuBarSection.allCases, id: \.self) { Text($0.label).tag($0) }
                }.labelsHidden().frame(width: 150).disabled(!model.canEdit)
            } else { Text(tr("Managed by macOS")).font(Theme.secondary).foregroundStyle(Theme.textSecondary) }
        }.padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
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
