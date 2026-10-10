import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

/// The place to actually clean: a resizable window with categories, a sortable list grouped by
/// project, details for the selected item (paths, sessions, why it is safe) and the Clean button.
/// The popover's Disk tab only summarises and opens this.
enum DiskWindow {
    private static var window: NSWindow?

    static func show(_ model: DiskModel) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: Host(model: model).frame(minWidth: 880, minHeight: 540))
            // Let the window keep the size we give it (and the user drags to); only the minimum comes from SwiftUI.
            host.sizingOptions = [.minSize]
            w.contentViewController = host
            // The hosting controller shrinks the window to its minimum; give it room, then place it.
            if !w.setFrameUsingName("DiskCleanup") {
                w.setContentSize(NSSize(width: 1060, height: 680))
                w.center()
            }
            // Only now: autosaving earlier would record the shrunken size the content was first laid out at.
            w.setFrameAutosaveName("DiskCleanup")
            window = w
        }
        window?.title = tr("Disk Cleanup")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if model.report == nil && !model.scanning { model.scan() }
    }

    struct Host: View {
        @ObservedObject var model: DiskModel
        @AppStorage(L10n.defaultsKey) private var language = "system"
        var body: some View { DiskCleanupView(model: model).id(language) }
    }
}

extension DiskModel {
    /// One line per item for the confirmation: how it goes, size, name, paths.
    var planLines: [String] {
        selectedItems.map { i in
            let how = i.safety == .safe ? tr("delete") : tr("trash")
            let paths = trCount(i.paths.count, "%1$@ path", "%1$@ paths")
            return "\(how.padding(toLength: 7, withPad: " ", startingAt: 0)) \(ByteFormat.string(i.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(i.title) (\(paths))"
        }
    }

    var confirmSummary: String {
        let items = selectedItems
        let trash = items.filter { $0.safety != .safe }
        var parts = [trCount(items.count, "%1$@ item.", "%1$@ items.")]
        if trash.count < items.count { parts.append(tr("Caches and build output are deleted.")) }
        if !trash.isEmpty {
            parts.append(trCount(trash.count, "%1$@ item with your data (sessions, models, worktrees) goes to the Trash.",
                                 "%1$@ items with your data (sessions, models, worktrees) go to the Trash."))
        }
        return parts.joined(separator: " ")
    }

    func selectSafe() { selected = Set((report?.items ?? []).filter { $0.cleanable && $0.safety == .safe }.map(\.id)) }
}

struct DiskCleanupView: View {
    @ObservedObject var model: DiskModel
    @State private var sidebar: CleanCategory? = .aiSessions
    @State private var focus: String?
    @State private var search = ""
    @State private var sort: Sort = .size
    @State private var confirming = false

    enum Sort: String, CaseIterable, Identifiable {
        case size, lastUsed, name
        var id: String { rawValue }
        var label: String { self == .size ? tr("Size") : self == .lastUsed ? tr("Last used") : tr("Name") }
    }

    var items: [CleanItem] { model.report?.items ?? [] }

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebar) {
                Section {
                    ForEach(CleanCategory.allCases, id: \.self) { c in
                        let inCat = items.filter { $0.category == c }
                        if !inCat.isEmpty || model.scanning {
                            HStack {
                                Label(c.title, systemImage: Self.icon(c))
                                Spacer()
                                Text(ByteFormat.string(model.report?.bytes(in: c) ?? 0)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .tag(c)
                        }
                    }
                } header: {
                    Text(model.report.map { tr("%1$@ reclaimable", ByteFormat.string($0.totalBytes)) } ?? tr("Disk Cleanup"))
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } content: {
            VStack(spacing: 0) {
                statusBar
                itemList
                Divider()
                footer
            }
            .navigationSplitViewColumnWidth(min: 420, ideal: 520)
        } detail: {
            if let id = focus, let item = items.first(where: { $0.id == id }) {
                DiskItemDetail(model: model, item: item)
            } else {
                Text(tr("Select an item to see what it holds and why it can go."))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: Text(tr("Search")))
        .toolbar {
            ToolbarItemGroup {
                Picker(tr("Sort"), selection: $sort) { ForEach(Sort.allCases) { Text($0.label).tag($0) } }.pickerStyle(.menu)
                Picker("", selection: $model.scope) { ForEach(DiskModel.Scope.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).disabled(model.scanning)
                if model.scanning {
                    Button(tr("Stop")) { model.stop() }.disabled(model.stopping)
                } else {
                    Button { model.scan() } label: { Label(tr("Scan again"), systemImage: "arrow.clockwise") }
                }
            }
        }
        .sheet(isPresented: $confirming) {
            ConfirmSheet(title: tr("Clean %1$@?", ByteFormat.string(model.selectedBytes)), summary: model.confirmSummary,
                         destructive: model.selectedItems.contains { $0.safety == .safe }, heading: tr("What will be removed"),
                         lines: model.planLines,
                         footnote: tr("Removed items are listed in ~/Library/Logs/Thermo/clean.log. Anything changed since the scan is skipped."),
                         confirmTitle: tr("Clean"),
                         confirm: { confirming = false; model.clean() }, cancel: { confirming = false })
        }
    }

    @ViewBuilder var statusBar: some View {
        if model.scanning || model.cleaning || model.stale || model.lastResult != nil {
            HStack(spacing: 8) {
                if model.scanning || model.cleaning { ProgressView().controlSize(.small) }
                Text(model.cleaning ? tr("Cleaning %1$@ of %2$@: %3$@", String(model.cleaningDone + 1), String(model.cleaningTotal), model.cleaningStep)
                     : model.scanning ? tr("scanning… %1$@", model.progress)
                     : model.stale ? tr("Scope changed — scan again to update the list.") : (model.lastResult ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
    }

    /// Items of the chosen category, filtered and sorted; build output is grouped by project.
    var shown: [CleanItem] {
        var list = items.filter { $0.category == sidebar }
        if !search.isEmpty {
            let q = search.lowercased()
            list = list.filter { ($0.title + " " + $0.detail + " " + ($0.note ?? "")).lowercased().contains(q) }
        }
        switch sort {
        case .size: list.sort { $0.bytes > $1.bytes }
        case .lastUsed: list.sort { ($0.lastUsed ?? .distantFuture) < ($1.lastUsed ?? .distantFuture) }
        case .name: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return list
    }

    var itemList: some View {
        let list = shown
        let groups = Dictionary(grouping: list, by: { $0.group ?? "" })
        let grouped = sidebar == .projects && groups.count > 1
        return List(selection: $focus) {
            if list.isEmpty {
                Text(model.scanning ? tr("Looking…") : tr("Nothing here.")).foregroundStyle(.secondary)
            } else if grouped {
                // One section per project folder: its build outputs together, newest use shown once.
                ForEach(groupOrder(groups), id: \.self) { g in
                    let rows = groups[g] ?? []
                    Section {
                        ForEach(rows) { row($0).tag($0.id) }
                    } header: {
                        HStack {
                            Text(FSPath.tilde(g)).font(.callout.weight(.semibold))
                            if let used = rows.compactMap(\.lastUsed).max() {
                                Text(tr("last used %1$@", AgeFormat.string(used))).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ByteFormat.string(rows.reduce(0) { $0 + $1.bytes })).monospacedDigit()
                        }
                    }
                }
            } else {
                ForEach(list) { row($0).tag($0.id) }
            }
        }
    }

    func groupOrder(_ groups: [String: [CleanItem]]) -> [String] {
        groups.keys.sorted { a, b in
            switch sort {
            case .size: return (groups[a] ?? []).reduce(0) { $0 + $1.bytes } > (groups[b] ?? []).reduce(0) { $0 + $1.bytes }
            case .lastUsed: return ((groups[a] ?? []).compactMap(\.lastUsed).max() ?? .distantFuture) < ((groups[b] ?? []).compactMap(\.lastUsed).max() ?? .distantFuture)
            case .name: return a.localizedStandardCompare(b) == .orderedAscending
            }
        }
    }

    func row(_ i: CleanItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: model.selected.contains(i.id) ? "checkmark.square.fill" : "square")
                .foregroundStyle(i.cleanable ? (model.selected.contains(i.id) ? Color.accentColor : .secondary) : Color.secondary.opacity(0.4))
                .onTapGesture { if i.cleanable { model.toggle(i) } }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(i.title).lineLimit(1)
                    SafetyTag(safety: i.safety, info: i.paths.isEmpty)
                }
                Text(i.blocked ?? i.detail).font(.caption).foregroundStyle(i.blocked != nil ? Color.orange : .secondary).lineLimit(1)
            }
            Spacer()
            if let used = i.lastUsed {
                Text(AgeFormat.string(used)).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            }
            Text(ByteFormat.string(model.selectedItems.first { $0.id == i.id }?.bytes ?? i.bytes))
                .monospacedDigit().frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(tr("Show in Finder")) { model.reveal(i) }.disabled(i.paths.isEmpty)
            Button(tr("Copy ID")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(i.id, forType: .string) }
        }
    }

    var footer: some View {
        HStack {
            Button(tr("None")) { model.selected = [] }.disabled(model.selected.isEmpty)
            Button(tr("Safe")) { model.selectSafe() }
            Spacer()
            Text(trCount(model.selectedItems.count, "%1$@ item selected", "%1$@ items selected")).foregroundStyle(.secondary)
            Button(tr("Clean %1$@", ByteFormat.string(model.selectedBytes))) { confirming = true }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(model.selectedItems.isEmpty || model.cleaning || model.scanning)
        }
        .padding(10)
    }

    static func icon(_ c: CleanCategory) -> String {
        switch c {
        case .aiSessions: return "bubble.left.and.text.bubble.right"
        case .aiModels: return "cpu"
        case .aiCaches: return "sparkles"
        case .devCaches: return "hammer"
        case .xcode: return "swift"
        case .projects: return "folder"
        case .browsers: return "globe"
        case .system: return "gearshape"
        }
    }
}

enum FSPath {
    static func tilde(_ p: String) -> String {
        let h = NSHomeDirectory()
        return p.hasPrefix(h + "/") ? "~" + p.dropFirst(h.count) : p
    }
}

/// Right column: everything about one item.
struct DiskItemDetail: View {
    @ObservedObject var model: DiskModel
    let item: CleanItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                    SafetyTag(safety: item.safety, info: item.paths.isEmpty)
                    Spacer()
                    Text(ByteFormat.string(item.bytes)).font(.title3.monospacedDigit())
                }
                Text(item.detail).foregroundStyle(.secondary).textSelection(.enabled)
                if let b = item.blocked { Label(b, systemImage: "hand.raised").foregroundStyle(.orange) }
                if let n = item.note { Text(n).fixedSize(horizontal: false, vertical: true) }
                if let h = item.hint { Text(tr("Run: %1$@", h)).font(.callout.monospaced()).textSelection(.enabled) }
                Text(safetyText).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                if let parts = item.parts, parts.count > 1 {
                    HStack {
                        Text(trCount(parts.count, "%1$@ session", "%1$@ sessions")).font(.headline)
                        Spacer()
                        Button(tr("All")) { model.excluded[item.id] = nil; if !model.selected.contains(item.id) { model.toggle(item) } }
                        Button(tr("None")) { model.selected.remove(item.id); model.excluded[item.id] = nil }
                    }
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(parts) { p in
                            let on = model.isTicked(p, of: item)
                            HStack(spacing: 8) {
                                Image(systemName: on ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(on ? Color.accentColor : .secondary)
                                    .onTapGesture { model.toggle(p, of: item) }
                                Text(p.title).lineLimit(1)
                                Spacer()
                                if let d = p.lastUsed { Text(AgeFormat.string(d)).font(.caption).foregroundStyle(.secondary) }
                                Text(ByteFormat.string(p.bytes)).font(.callout.monospacedDigit()).frame(width: 70, alignment: .trailing)
                            }
                            .contextMenu {
                                Button(tr("Show in Finder")) {
                                    NSWorkspace.shared.activateFileViewerSelecting(p.paths.prefix(20).map { URL(fileURLWithPath: $0) })
                                }
                            }
                        }
                    }
                } else if !item.paths.isEmpty {
                    Text(trCount(item.paths.count, "%1$@ path", "%1$@ paths")).font(.headline)
                    ForEach(item.paths.prefix(200), id: \.self) { p in
                        HStack {
                            Text(FSPath.tilde(p)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Spacer()
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) } label: {
                                Image(systemName: "magnifyingglass")
                            }.buttonStyle(.borderless).help(tr("Show in Finder"))
                        }
                    }
                    if item.paths.count > 200 { Text(tr("… and %1$@ more", String(item.paths.count - 200))).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .padding(16)
        }
    }

    var safetyText: String {
        switch item.safety {
        case .safe: return tr("Safe: this is regenerated automatically (caches, logs, build output). It is deleted, not moved to the Trash.")
        case .review: return tr("Your data, probably no longer needed. It goes to the Trash, so you can still get it back.")
        case .risky: return tr("Could lose work (for example uncommitted changes). Only removed when you tick it yourself.")
        }
    }
}
