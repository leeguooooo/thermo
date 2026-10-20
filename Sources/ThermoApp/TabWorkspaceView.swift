import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

@MainActor
enum TabQuickAction {
    static var requested = false
    static let notification = Notification.Name("dev.thermo.archiveBackgroundTabs")
    static func request() {
        requested = true
        MainWindow.show(.browser("Google Chrome"))
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

@MainActor
final class TabWorkspaceModel: ObservableObject {
    let app: String
    @Published var inventory: TabWorkspace.Inventory?
    @Published var saved: [TabWorkspace.Archive] = []
    @Published var selected: Set<String> = []
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var allWindows = false
    @Published var window: Int?
    static var loadedApps = Set<String>()
    struct Preview: Codable { var inventory: TabWorkspace.Inventory; var saved: [TabWorkspace.Archive] }
    private(set) var isPreview = false
    init(app: String, preview: Preview? = nil) {
        self.app = app
        if let preview {
            inventory = preview.inventory; saved = preview.saved; isPreview = true; Self.loadedApps.insert(app); return
        }
        let args = CommandLine.arguments
        if args.contains("--offscreen"), let i = args.firstIndex(of: "--tabs-fixture"), i + 1 < args.count {
            do {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let data = try decoder.decode(Preview.self, from: Data(contentsOf: URL(fileURLWithPath: args[i + 1])))
                inventory = data.inventory; saved = data.saved; isPreview = true
                Self.loadedApps.insert(app)
            } catch { self.error = error.localizedDescription; isPreview = true; Self.loadedApps.insert(app) }
        }
    }
    var pages: [TabWorkspace.Page] {
        (inventory?.pages ?? []).filter { allWindows || $0.tab.window == (window ?? inventory?.pages.first?.tab.window) }
    }
    func windowLabel(_ id: Int) -> String {
        var ids: [Int] = []
        for page in inventory?.pages ?? [] where !ids.contains(page.tab.window) { ids.append(page.tab.window) }
        let label = tr("Window %1$@", String((ids.firstIndex(of: id) ?? 0) + 1))
        let active = inventory?.pages.first { $0.tab.window == id && $0.tab.active == true }
        return label + (active.map { " · " + String(($0.tab.title.isEmpty ? TabWorkspace.site($0.tab.url) : $0.tab.title).prefix(28)) } ?? "")
    }
    var chosen: [TabWorkspace.Page] { pages.filter { selected.contains($0.id) } }
    var candidates: [TabWorkspace.Page] { pages.filter(\.canArchive) }
    func selectWindow(_ id: Int) { window = id; selected = [] }
    func selectAllWindows(_ value: Bool) { allWindows = value; selected = [] }
    func refresh() {
        guard !busy, !isPreview else { return }; busy = true; error = nil
        let app = app
        Task {
            do {
                let inv = try await Task.detached { try await TabWorkspace.inventory(app: app) }.value
                let records = try await Task.detached { try TabWorkspace.archives() }.value
                Self.loadedApps.insert(app)
                inventory = inv; saved = records.filter { $0.app == app }
                selected.formIntersection(Set(inv.pages.map(\.id)))
            } catch { self.error = tr(error.localizedDescription); Self.loadedApps.insert(app) }
            busy = false
        }
    }
    func group(_ name: String?) {
        let selection = name == nil ? pages : chosen
        guard !selection.isEmpty, !busy, !isPreview else { return }; busy = true; error = nil
        Task {
            do { try await Task.detached { try TabWorkspace.assign(selection, name: name) }.value }
            catch { self.error = error.localizedDescription }
            busy = false; refresh()
        }
    }
    func archive(_ selection: [TabWorkspace.Page], name: String) {
        guard !busy, !isPreview else { return }; busy = true; error = nil; let app = app
        Task {
            do {
                let record = try await Task.detached { try await TabWorkspace.archive(selection, app: app, name: name) }.value
                notice = tr("Saved %1$@ pages; closed %2$@. Skipped or unconfirmed pages remain listed in the saved batch.", String(record.entries.count), String(record.closed))
                selected.subtract(selection.map(\.id))
            } catch { self.error = error.localizedDescription }
            busy = false; refresh()
        }
    }
    func restore(_ record: TabWorkspace.Archive, destinationWindow: Int? = nil) {
        guard !busy, !isPreview else { return }; busy = true; error = nil
        Task {
            do {
                let result = try await Task.detached { try TabWorkspace.restore(record.id, destinationWindow: destinationWindow) }.value
                let restored = result.entries.filter { $0.restoreState == "restored" }.count
                notice = tr("%1$@ pages reopened. Unconfirmed operations are not retried automatically.", String(restored))
            } catch { self.error = error.localizedDescription }
            busy = false; refresh()
        }
    }
}

enum TabWorkspaceTask: String, CaseIterable, Identifiable {
    case organize, archive, saved
    var id: String { rawValue }
    var title: String {
        switch self {
        case .organize: return tr("Organize in Chrome")
        case .archive: return tr("Save and close for later")
        case .saved: return tr("Saved for later")
        }
    }
}

struct TabWorkspaceView: View {
    @StateObject private var model: TabWorkspaceModel
    @State private var search = ""
    @State private var groupName = ""
    @State private var batchName = ""
    @State private var plan: Plan?
    @State private var categorizing = false
    @State private var collapsed: Set<String> = []
    @Binding var task: TabWorkspaceTask
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    struct Plan: Identifiable {
        let id = UUID()
        var pages: [TabWorkspace.Page] = []
        var archive: TabWorkspace.Archive?
        var destinationWindow: Int?
        var name: String = ""
    }
    init(app: String, task: Binding<TabWorkspaceTask>) {
        _model = StateObject(wrappedValue: TabWorkspaceModel(app: app))
        _task = task
    }
    var groupNames: [String] { Array(Set(filtered.map(\.group))).sorted() }
    var filtered: [TabWorkspace.Page] {
        model.pages.filter { search.isEmpty || ($0.tab.title + " " + $0.tab.url + " " + $0.group).localizedCaseInsensitiveContains(search) }
    }
    var eligibleSelection: [TabWorkspace.Page] { model.chosen.filter(\.canArchive) }
    /// What a tick can be put on: closable tabs, or any tab while sorting the list into categories.
    func pickable(_ pages: [TabWorkspace.Page]) -> [TabWorkspace.Page] {
        model.busy ? [] : pages.filter { $0.canArchive || categorizing }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if task != .saved { scopePicker } else { savedToolbar }
                if let error = model.error {
                    NoticeBanner(text: error + (model.inventory != nil ? "\n" + tr("This is the previous list. Refresh before taking action.") : ""))
                }
                if let notice = model.notice { NoticeBanner(text: notice, dismiss: { model.notice = nil }) }
                if task != .saved, let hint = model.inventory?.hint {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "exclamationmark.shield").foregroundStyle(Theme.caution)
                        Text(tr("Some browser protection details are missing")).font(Theme.secondary.weight(.medium)).foregroundStyle(Theme.textPrimary)
                        InfoButton(text: tr("Refresh after connecting the browser extension. Tabs with unknown protection stay open.") + "\n\n" + tr(hint),
                                   title: tr("Connection details"))
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.caution.opacity(0.08)))
                }
            }
            .padding(.horizontal, Theme.pagePadding).padding(.bottom, Theme.Space.m)
            switch task {
            case .saved: savedGroups
            case .organize:
                ScrollView {
                    NativeTabOrganizerView(app: model.app, pages: model.pages, nativeGroups: model.inventory?.nativeGroups ?? [],
                                           working: $model.busy,
                                           previewOnly: model.isPreview, refresh: model.refresh)
                        .padding(.horizontal, Theme.pagePadding).padding(.bottom, Theme.Space.xl)
                        .frame(maxWidth: Theme.pageWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .archive: archiveTabs
            }
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: TabQuickAction.notification)) { _ in model.refresh() }
        .onChange(of: model.busy) { busy in
            if !busy && TabQuickAction.requested && model.app == "Google Chrome" {
                TabQuickAction.requested = false
                task = .archive; model.allWindows = false; model.window = nil
                if !model.candidates.isEmpty { requestArchive(model.candidates) }
            }
        }
        .sheet(item: $plan) { value in
            ConfirmSheet(title: value.archive == nil ? tr("Save links and close %1$@ tabs?", String(value.pages.count)) : tr("Reopen saved tabs?"),
                         summary: value.archive == nil ? tr("Links are saved on this Mac first, then only the listed tabs are closed. You can reopen them from Saved for later.")
                             : tr("Only tabs confirmed closed and not already reopened will be opened. Other entries stay as they are."),
                         destructive: value.archive == nil, heading: tr("Pages affected"),
                         lines: value.archive.map { $0.entries.filter { $0.status == "closed" && $0.restoreState == nil }.map { $0.page.tab.title + " · " + TabWorkspace.site($0.page.tab.url) } }
                             ?? value.pages.map { $0.tab.title + " · " + TabWorkspace.site($0.tab.url) },
                         footnote: tr("Unsaved form input and page state are not saved. Current, pinned, audio, private and agent tabs stay open; pages that changed are skipped."),
                         confirmTitle: value.archive == nil ? tr("Save links and close tabs") : tr("Reopen tabs"),
                         confirm: {
                             plan = nil
                             if let record = value.archive { model.restore(record, destinationWindow: value.destinationWindow) }
                             else { model.archive(value.pages, name: value.name) }
                         }, cancel: { plan = nil })
        }
    }

    var refreshButton: some View {
        Button { model.refresh() } label: {
            HStack(spacing: 6) {
                if model.busy { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                Text(model.busy ? tr("Reading tabs…") : tr("Refresh tabs"))
            }
        }
        .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(model.busy)
    }

    var savedToolbar: some View {
        HStack {
            Text(tr("%1$@ saved", String(model.saved.count))).font(Theme.secondary.monospacedDigit()).foregroundStyle(Theme.textSecondary)
            Spacer()
            refreshButton
        }
    }

    var scopePicker: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.m) { scopeControls; scopeCount; Spacer(); refreshButton }.frame(minWidth: 600)
            VStack(alignment: .leading, spacing: Theme.Space.s) { scopeControls; HStack { scopeCount; Spacer(); refreshButton } }
        }
    }
    var scopeControls: some View {
        HStack(spacing: Theme.Space.s) {
            ThermoTabs(selection: Binding(get: { model.allWindows }, set: { model.selectAllWindows($0) }),
                       options: [(false, tr("One window")), (true, tr("All Chrome windows"))], size: .small, label: tr("Scope"))
            if !model.allWindows, let inventory = model.inventory {
                Picker(tr("Window"), selection: Binding(get: { model.window ?? inventory.pages.first?.tab.window ?? 0 }, set: { model.selectWindow($0) })) {
                    ForEach(Array(Set(inventory.pages.map { $0.tab.window })).sorted(), id: \.self) { id in Text(model.windowLabel(id)).tag(id) }
                }.labelsHidden().controlSize(.small).frame(maxWidth: 230)
            }
        }
    }
    var scopeCount: some View {
        Text(tr("%1$@ tabs · %2$@ protected", String(model.pages.count), String(model.pages.filter { !$0.canArchive }.count)))
            .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
            .contentTransition(.numericText())
    }
    static func archivePlan(_ selection: [TabWorkspace.Page], name: String) -> Plan? {
        let pages = selection.filter(\.canArchive)
        guard !pages.isEmpty else { return nil }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Plan(pages: pages, name: name.isEmpty ? tr("Saved tabs") : name)
    }
    func requestArchive(_ pages: [TabWorkspace.Page], name: String? = nil) {
        plan = Self.archivePlan(pages, name: name ?? batchName)
    }
    var archiveTabs: some View {
        let all = pickable(filtered)
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "archivebox").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.accent)
                        Text(tr("Put unused tabs away for later")).font(Theme.heading).foregroundStyle(Theme.textPrimary)
                        InfoButton(text: tr("Save their links on this Mac, then close the tabs. Reopen them from Saved for later when you need them.")
                                   + "\n\n" + tr("Form input, scroll positions and sign-in state are not saved."))
                        Spacer()
                    }
                    HStack(spacing: Theme.Space.s) {
                        SearchField(text: $search, prompt: tr("Search title, website or category"))
                        archiveName.frame(maxWidth: 260)
                    }
                    if model.candidates.isEmpty && !model.busy {
                        Text(tr("No tabs can be safely closed in this scope. Protected tabs are kept."))
                            .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                    if model.busy && model.inventory == nil { SkeletonList(rows: 5) }
                    ForEach(groupNames, id: \.self) { group in groupRow(group) }
                    if filtered.isEmpty && !(model.busy && model.inventory == nil) {
                        InspectorPanel {
                            EmptyState(symbol: "rectangle.stack", title: search.isEmpty ? tr("No tabs in this scope. Choose another window or refresh.") : tr("No matching pages."))
                        }
                    }
                    DisclosureGroup(isExpanded: $categorizing) {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(tr("These categories only change the list in Thermo. They do not change Chrome groups or close any tabs."))
                                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                            ViewThatFits(in: .horizontal) {
                                HStack { categoryName; categoryActions }.frame(minWidth: 620)
                                VStack(alignment: .leading, spacing: Theme.Space.s) { categoryName; categoryActions }
                            }
                        }.padding(.top, Theme.Space.s)
                    } label: {
                        Text(tr("Optional: organize this list with your own categories")).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m).glass()
                }
                .padding(.horizontal, Theme.pagePadding).padding(.bottom, Theme.Space.xl)
                .frame(maxWidth: Theme.pageWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ActionBar {
                SelectAllButton(available: all.count, selected: all.filter { model.selected.contains($0.id) }.count,
                                selectAll: { model.selected.formUnion(all.map(\.id)) },
                                clear: { model.selected.subtract(all.map(\.id)) })
                if !model.selected.isEmpty {
                    Text(tr("%1$@ selected · %2$@ can be saved and closed", String(model.chosen.count), String(eligibleSelection.count)))
                        .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                        .contentTransition(.numericText())
                }
                Spacer()
                archivePrimary
            }
        }
    }
    var archiveName: some View {
        TextField(tr("Name this saved set (optional)"), text: $batchName).textFieldStyle(.plain).font(Theme.secondary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Color.white.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).strokeBorder(Theme.hairline))
    }
    var archivePrimary: some View {
        Button { requestArchive(model.selected.isEmpty ? model.candidates : eligibleSelection) } label: {
            Label(tr("Review saving %1$@ tabs", String(model.selected.isEmpty ? model.candidates.count : eligibleSelection.count)), systemImage: "archivebox")
        }.buttonStyle(PillButtonStyle(prominent: true)).disabled(model.busy || (model.selected.isEmpty ? model.candidates : eligibleSelection).isEmpty)
    }
    var categoryName: some View { TextField(tr("Category name for selected tabs"), text: $groupName).textFieldStyle(.roundedBorder) }
    var categoryActions: some View {
        HStack {
            Button(tr("Apply category")) { model.group(groupName) }.buttonStyle(PillButtonStyle()).controlSize(.small)
                .disabled(model.chosen.isEmpty || groupName.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
            Button(tr("Reset this list by website")) { model.group(nil) }.buttonStyle(PillButtonStyle()).controlSize(.small)
                .disabled(model.busy || model.pages.isEmpty)
        }
    }
    /// One website or category: a header that ticks or clears the whole group, then its tabs.
    func groupRow(_ name: String) -> some View {
        let pages = filtered.filter { $0.group == name }
        let closable = pages.filter(\.canArchive)
        let picks = pickable(pages)
        let open = !collapsed.contains(name)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                SelectAllButton(title: name, available: picks.count, selected: picks.filter { model.selected.contains($0.id) }.count,
                                selectAll: { model.selected.formUnion(picks.map(\.id)) },
                                clear: { model.selected.subtract(picks.map(\.id)) })
                Text(tr("%1$@ tabs", String(pages.count))).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                Spacer()
                if closable.isEmpty {
                    Label(tr("All tabs kept"), systemImage: "lock.fill").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                } else {
                    Button(tr("Save and close %1$@", String(closable.count))) { requestArchive(closable, name: name) }
                        .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(model.busy)
                }
                Button {
                    withAnimation(Theme.standard.unlessReduced(reduceMotion)) {
                        if open { collapsed.insert(name) } else { collapsed.remove(name) }
                    }
                } label: { DisclosureChevron(expanded: open) }
                .buttonStyle(.plain).accessibilityLabel(name).accessibilityValue(open ? tr("Expanded") : tr("Collapsed"))
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, 10)
            if open {
                ForEach(pages) { page in
                    InspectorDivider(inset: 44)
                    tabRow(page)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .glass()
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
    func tabRow(_ page: TabWorkspace.Page) -> some View {
        let on = model.selected.contains(page.id)
        let locked = !page.canArchive && !categorizing
        let title = page.tab.title.isEmpty ? page.tab.url : page.tab.title
        return HStack(alignment: .center, spacing: Theme.Space.s) {
            SelectToggle(selected: on, locked: locked, label: title) {
                if on { model.selected.remove(page.id) } else { model.selected.insert(page.id) }
            }
            .disabled(model.busy)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(TabWorkspace.site(page.tab.url)).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer()
            if model.allWindows { Text(model.windowLabel(page.tab.window)).font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1) }
            if let reason = page.protectedReason { StatusTag(text: tr(reason)) }
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)
        .background(on ? Theme.accent.opacity(0.07) : .clear)
        .hoverHighlight()
    }
    var savedGroups: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                if model.saved.isEmpty {
                    InspectorPanel {
                        VStack(spacing: Theme.Space.m) {
                            EmptyState(symbol: "archivebox", title: tr("Nothing saved for later yet"),
                                       detail: tr("Use Save and close to keep links here before putting unused tabs away."))
                                .padding(.bottom, -Theme.Space.xl)
                            Button(tr("Choose tabs to save")) { task = .archive }.buttonStyle(PillButtonStyle(prominent: true))
                                .padding(.bottom, Theme.Space.xl)
                        }
                    }
                }
                ForEach(model.saved) { record in
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.name).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Text(record.saved, style: .date).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            Text(tr("%1$@ saved · %2$@ closed · %3$@ not yet reopened", String(record.entries.count), String(record.closed), String(record.remaining)))
                                .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                            Button(tr("Reopen %1$@ tabs", String(record.remaining))) { plan = Plan(archive: record) }
                                .buttonStyle(PillButtonStyle(prominent: record.remaining > 0)).controlSize(.small)
                                .disabled(record.remaining == 0 || model.busy)
                        }
                        if record.remaining == 0 {
                            Text(tr("No confirmed closed tabs remain to reopen.")).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        }
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 0) {
                                Menu(tr("Reopen in a specific window")) {
                                    ForEach(Array(Set((model.inventory?.pages ?? []).map { $0.tab.window })).sorted(), id: \.self) { window in
                                        Button(model.windowLabel(window)) { plan = Plan(archive: record, destinationWindow: window) }
                                    }
                                }.controlSize(.small).fixedSize().disabled(record.remaining == 0 || model.busy).padding(.vertical, Theme.Space.s)
                                ForEach(record.entries) { entry in
                                    InspectorDivider(inset: 0)
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.page.tab.title).font(Theme.secondary).foregroundStyle(Theme.textPrimary)
                                            Link(entry.page.tab.url, destination: URL(string: entry.page.tab.url) ?? URL(string: "about:blank")!)
                                                .font(Theme.caption).lineLimit(1)
                                        }
                                        Spacer()
                                        Text(tr(entry.restoreState ?? entry.status)).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                    }.padding(.vertical, 6)
                                }
                            }
                        } label: {
                            Text(tr("Links, results and reopening options")).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(Theme.Space.l).glass()
                }
            }
            .padding(.horizontal, Theme.pagePadding).padding(.bottom, Theme.Space.xl)
            .frame(maxWidth: Theme.pageWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
