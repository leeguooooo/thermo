import AppKit
import QuickLookUI
import SearchCore
import SwiftUI
import ThermoL10n

@MainActor final class LocalSearchPanel: NSWindowController, NSWindowDelegate {
    static let shared = LocalSearchPanel()
    private var previousApplication: NSRunningApplication?
    private var preview: NSWindow?
    private let model = LocalSearchModel.shared
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
    init() {
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
                          styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = tr("Search apps and files"); panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true; panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true; panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false; panel.isMovableByWindowBackground = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.becomesKeyOnlyIfNeeded = false; panel.hidesOnDeactivate = false
        super.init(window: panel); panel.delegate = self
        panel.contentView = NSHostingView(rootView: LocalSearchView(model: model).ignoresSafeArea().preferredColorScheme(.dark))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func toggle() { window?.isVisible == true ? hide() : show() }
    func show(settings: Bool = false) {
        model.start()
        model.refreshApplications()
        if window?.isVisible != true {
            let front = NSWorkspace.shared.frontmostApplication
            previousApplication = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main, let window {
                let visible = screen.visibleFrame
                window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.maxY - window.frame.height - visible.height * 0.16))
            }
        }
        model.showSettings = settings
        model.submit(); window?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .localSearchFocus, object: nil)
    }
    func hide(restoreFocus: Bool = true) {
        preview?.close(); preview = nil
        window?.orderOut(nil)
        if restoreFocus, let previousApplication, !previousApplication.isTerminated { previousApplication.activate(options: []) }
        previousApplication = nil
    }
    func windowDidResignKey(_ notification: Notification) {
        guard !model.presentingDialog, !model.showSettings, model.aliasTarget == nil, preview?.isVisible != true else { return }
        hide(restoreFocus: false)
    }
    func previewSelected() {
        guard let item = model.selected, item.kind != .application else { return }
        guard FileManager.default.fileExists(atPath: item.path) else { model.error = tr("This item is no longer available. Refresh the index."); return }
        if preview?.isVisible == true { preview?.close(); preview = nil; window?.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = item.name; panel.isReleasedWhenClosed = false; panel.level = .floating
        guard let view = QLPreviewView(frame: panel.contentLayoutRect, style: .normal) else { return }
        view.autoresizingMask = [.width, .height]; view.shouldCloseWithWindow = true
        view.previewItem = URL(fileURLWithPath: item.path) as NSURL
        panel.contentView = view; preview = panel; panel.center(); panel.makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name { static let localSearchFocus = Notification.Name("dev.thermo.search.focus") }

private struct LocalSearchView: View {
    @ObservedObject var model: LocalSearchModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 23, weight: .light)).foregroundStyle(Theme.textSecondary)
                LocalSearchInput(model: model).frame(height: 42)
                if model.searching { ProgressView().controlSize(.small).frame(width: 20) }
                Button { model.showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).help(tr("Search settings")).accessibilityLabel(tr("Search settings"))
            }.padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 14)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if let error = model.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.caution)
                    Text(tr(error)).font(Theme.secondary).textSelection(.enabled)
                    Spacer()
                    Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(tr("Dismiss"))
                }.padding(12).background(Theme.surface)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if model.response.items.isEmpty && !model.searching {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(model.query.isEmpty ? tr("Your apps, one shortcut away") : tr("No matching apps or files")).font(Theme.heading)
                                if model.preferences.roots.isEmpty {
                                    Text(tr("Add folders to search local files. Everything stays on this Mac.")).font(Theme.body).foregroundStyle(Theme.textSecondary)
                                    Button(tr("Add folders…")) { model.chooseFolder() }
                                } else {
                                    Text(model.indexing ? tr("Indexing file names. More results will appear as folders are read.") : tr("Try part of a name, an abbreviation or a different spelling.")).font(Theme.body).foregroundStyle(Theme.textSecondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(28)
                        }
                        ForEach(model.response.items) { item in
                            Button { model.selection = item.id; model.open(item) } label: {
                                HStack(spacing: 12) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 30, height: 30)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(item.name).font(Theme.rowTitle).lineLimit(1)
                                            if item.favorite { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Theme.caution) }
                                            if let alias = item.alias { Text(alias).font(Theme.caption).foregroundStyle(Theme.accent) }
                                        }
                                        Text((item.path as NSString).deletingLastPathComponent).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer(minLength: 8)
                                    Text(item.kind == .application ? tr("Application") : item.kind == .folder ? tr("Folder") : tr("File")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                }.padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(model.selection == item.id ? Theme.surfaceActive : Color.clear).clipShape(RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(item.id)
                                .accessibilityLabel(item.name + ", " + item.path).accessibilityValue(model.selection == item.id ? tr("Selected") : "")
                                .contextMenu {
                                    Button(tr("Open")) { model.selection = item.id; model.open(item) }
                                    Button(tr("Show in Finder")) { model.selection = item.id; model.revealSelected() }
                                    if item.kind != .application { Button(tr("Preview")) { model.selection = item.id; LocalSearchPanel.shared.previewSelected() } }
                                    Button(tr("Copy path")) { model.selection = item.id; model.copySelectedPath() }
                                    Divider()
                                    Button(item.favorite ? tr("Remove favorite") : tr("Add favorite")) { model.favorite(item) }
                                    Button(tr("Set alias…")) { model.aliasTarget = item }
                                }
                        }
                    }.padding(8)
                }.onChange(of: model.selection) { id in if let id { proxy.scrollTo(id, anchor: .center) } }
            }.frame(maxHeight: .infinity)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 14) {
                if model.indexing { ProgressView().controlSize(.mini); Text(tr("Indexing…")).font(Theme.caption) }
                else if model.response.limited { Text(tr("More matches; refine search")).font(Theme.caption).foregroundStyle(Theme.caution).lineLimit(1) }
                else if !model.response.complete { Text(tr("Some results are unavailable")).font(Theme.caption).foregroundStyle(Theme.caution).lineLimit(1) }
                else if model.preferences.roots.isEmpty {
                    Button(tr("Add folders…")) { model.chooseFolder() }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                } else { Text(tr("Local search")).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                Spacer()
                Button("↩ " + tr("Open")) { model.openSelected() }.buttonStyle(.plain).disabled(model.selected == nil)
                Button("⌘↩ " + tr("Show in Finder")) { model.revealSelected() }.buttonStyle(.plain).disabled(model.selected == nil)
                Button("⌘Y " + tr("Preview")) { LocalSearchPanel.shared.previewSelected() }.buttonStyle(.plain).disabled(model.selected == nil || model.selected?.kind == .application)
            }.font(Theme.caption).padding(.horizontal, 18).padding(.vertical, 12)
        }.foregroundStyle(Theme.textPrimary).background(Theme.canvas)
            .sheet(isPresented: $model.showSettings) { LocalSearchSettings(model: model) }
            .sheet(item: $model.aliasTarget) { item in LocalSearchAlias(model: model, item: item) }
    }
}

private struct LocalSearchInput: NSViewRepresentable {
    @ObservedObject var model: LocalSearchModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> Input {
        let field = Input(); field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .regular); field.textColor = .white
        field.placeholderString = tr("Search apps and files"); field.delegate = context.coordinator
        field.setAccessibilityLabel(tr("Search apps and files")); field.model = model
        context.coordinator.field = field
        return field
    }
    func updateNSView(_ field: Input, context: Context) {
        if field.stringValue != model.query, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = model.query }
    }
    final class Input: NSTextField {
        weak var model: LocalSearchModel?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); DispatchQueue.main.async { [weak self] in if let self { self.window?.makeFirstResponder(self) } } }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.modifierFlags.contains(.command), (currentEditor() as? NSTextView)?.hasMarkedText() != true else { return super.performKeyEquivalent(with: event) }
            if event.keyCode == 16 { LocalSearchPanel.shared.previewSelected(); return true }
            if event.keyCode == 36 { model?.revealSelected(); return true }
            if event.keyCode == 8, event.modifierFlags.contains(.shift) { model?.copySelectedPath(); return true }
            return super.performKeyEquivalent(with: event)
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: LocalSearchModel
        weak var field: Input?
        private var focus: NSObjectProtocol?
        init(model: LocalSearchModel) {
            self.model = model
            super.init()
            focus = NotificationCenter.default.addObserver(forName: .localSearchFocus, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let field = self?.field { field.window?.makeFirstResponder(field) } }
            }
        }
        deinit { if let focus { NotificationCenter.default.removeObserver(focus) } }
        func controlTextDidChange(_ notification: Notification) { if let field { model.query = field.stringValue } }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)): model.move(1)
            case #selector(NSResponder.moveUp(_:)): model.move(-1)
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true { model.revealSelected() }
                else { model.openSelected() }
            case #selector(NSResponder.cancelOperation(_:)):
                if !model.query.isEmpty { model.query = "" } else { LocalSearchPanel.shared.hide() }
            default: return false
            }
            return true
        }
    }
}

private struct LocalSearchAlias: View {
    @ObservedObject var model: LocalSearchModel
    let item: SearchItem
    @State private var alias = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Search alias")).font(Theme.heading)
            Text(item.name).font(Theme.body)
            TextField(tr("Short name or abbreviation"), text: $alias).textFieldStyle(.roundedBorder)
            Text(tr("An exact alias appears before other matches. Leave empty to remove it.")).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            HStack { Spacer(); Button(tr("Cancel")) { model.aliasTarget = nil }; Button(tr("Save")) { model.saveAlias(alias, for: item) }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 440).background(Theme.canvas).onAppear { alias = item.alias ?? "" }
    }
}

private struct LocalSearchSettings: View {
    @ObservedObject var model: LocalSearchModel
    @ObservedObject private var shortcut = LocalSearchShortcut.shared
    @State private var hidden = false
    @State private var ignores = true
    @State private var patterns = ""
    @State private var confirmingSpotlight = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(tr("Search settings")).font(Theme.heading); Spacer(); Button(tr("Done")) { model.showSettings = false } }
            Text(tr("Search folders")).font(Theme.rowTitle)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.preferences.roots, id: \.self) { root in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(root).font(Theme.body).textSelection(.enabled)
                                if let status = model.response.roots.first(where: { $0.path == root }) {
                                    Text(!status.available ? tr("Folder unavailable") : status.issue != nil ? tr("Some files could not be read") : status.indexedAt == 0 ? tr("Waiting to index") : tr("%@ indexed items", String(status.count)))
                                        .font(Theme.caption).foregroundStyle(status.issue == nil ? Theme.textTertiary : Theme.caution)
                                }
                            }
                            Spacer()
                            Button { model.removeFolder(root) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).accessibilityLabel(tr("Remove folder") + " " + root)
                        }
                    }
                }
            }.frame(height: min(130, max(56, CGFloat(model.preferences.roots.count) * 60)))
            HStack { Button(tr("Add folders…")) { model.chooseFolder() }; Button(tr("Refresh index")) { model.refresh() }; Spacer() }
            Toggle(tr("Include hidden files"), isOn: $hidden)
            Toggle(tr("Respect .gitignore, .ignore and .thermoignore"), isOn: $ignores)
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Excluded names or glob patterns, one per line")).font(Theme.secondary)
                TextEditor(text: $patterns).font(Theme.mono).frame(height: 70).scrollContentBackground(.hidden).padding(6).background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack { Spacer(); Button(tr("Apply file settings")) {
                var next = model.preferences; next.includeHiddenFiles = hidden; next.respectIgnoreFiles = ignores
                next.excludedPatterns = patterns.components(separatedBy: .newlines).filter { !$0.isEmpty }; model.configure(next)
            } }
            Divider()
            HStack { Text(tr("Global search shortcut")).font(Theme.rowTitle); Spacer(); SearchShortcutRecorder(model: shortcut).frame(width: 220, height: 28); Button(tr("Remove")) { shortcut.apply(nil) } }
            if let issue = shortcut.issue { Text(issue).font(Theme.caption).foregroundStyle(Theme.caution) }
            if shortcut.spotlightReleased || shortcut.binding?.sameGesture(LocalSearchShortcut.commandSpace) != true { HStack {
                if let holder = shortcut.commandSpaceHolder, !shortcut.spotlightReleased {
                    Text(LocalSearchShortcut.heldMessage(holder)).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button(tr("Open %@", holder.name)) { NSWorkspace.shared.open(holder.app) }
                } else {
                    Text(shortcut.spotlightReleased ? tr("Spotlight's ⌘Space is turned off so Thermo search can use it.") : tr("⌘Space is Spotlight's shortcut. Thermo can turn it off and use it for search."))
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if shortcut.spotlightReleased { Button(tr("Give ⌘Space back to Spotlight")) { shortcut.giveBackToSpotlight() } }
                    else { Button(tr("Use ⌘Space…")) { confirmingSpotlight = true } }
                }
            } }
            HStack { Text(tr("History, aliases and file names stay on this Mac.")).font(Theme.caption).foregroundStyle(Theme.textSecondary); Spacer(); Button(tr("Clear search history")) { model.clearHistory() } }
        }.padding(24).frame(width: 610).foregroundStyle(Theme.textPrimary).background(Theme.canvas)
            .alert(tr("Use ⌘Space for Thermo search?"), isPresented: $confirmingSpotlight) {
                Button(tr("Cancel"), role: .cancel) {}
                Button(tr("Use ⌘Space")) { shortcut.takeOverSpotlight() }
            } message: {
                Text(tr("Thermo turns off Spotlight's ⌘Space in Keyboard Shortcuts. Spotlight still opens from the menu bar. Give it back here, or by choosing another search shortcut."))
            }
            // Re-checked on return from another app, where the user may have just changed its shortcut.
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in shortcut.refreshCommandSpaceHolder() }
            .onAppear { shortcut.refreshCommandSpaceHolder(); hidden = model.preferences.includeHiddenFiles; ignores = model.preferences.respectIgnoreFiles; patterns = model.preferences.excludedPatterns.joined(separator: "\n") }
    }
}
