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
    @State private var task: TabWorkspaceTask = {
        let args = CommandLine.arguments
        if args.contains("--offscreen"), let i = args.firstIndex(of: "--tabs-task"), i + 1 < args.count {
            return TabWorkspaceTask(rawValue: args[i + 1]) ?? .organize
        }
        return .organize
    }()
    struct Plan: Identifiable {
        let id = UUID()
        var pages: [TabWorkspace.Page] = []
        var archive: TabWorkspace.Archive?
        var destinationWindow: Int?
        var name: String = ""
    }
    init(app: String) { _model = StateObject(wrappedValue: TabWorkspaceModel(app: app)) }
    var groupNames: [String] { Array(Set(filtered.map(\.group))).sorted() }
    var filtered: [TabWorkspace.Page] {
        model.pages.filter { search.isEmpty || ($0.tab.title + " " + $0.tab.url + " " + $0.group).localizedCaseInsensitiveContains(search) }
    }
    var eligibleSelection: [TabWorkspace.Page] { model.chosen.filter(\.canArchive) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Make your tabs easier to manage")).font(.title2.bold())
                    Text(tr("Group tabs without closing them, or save links and close tabs you are not using."))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button { model.refresh() } label: {
                    Label(model.busy ? tr("Reading tabs…") : tr("Refresh tabs"), systemImage: "arrow.clockwise")
                }.disabled(model.busy).buttonStyle(PillButtonStyle())
            }
            Picker(tr("What would you like to do?"), selection: $task) {
                ForEach(TabWorkspaceTask.allCases) { task in Text(task.title).tag(task) }
            }.pickerStyle(.segmented).labelsHidden()
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                if model.inventory != nil { Text(tr("This is the previous list. Refresh before taking action.")).font(.caption).foregroundStyle(.secondary) }
            }
            if let notice = model.notice { Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green) }
            if model.busy { HStack { ProgressView().controlSize(.small); Text(tr("Reading or updating tabs…")).font(.caption).foregroundStyle(.secondary) } }
            if task == .saved { savedGroups }
            else {
                scopePicker
                if let hint = model.inventory?.hint {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(tr("Some browser protection details are missing"), systemImage: "exclamationmark.shield").foregroundStyle(.orange)
                        Text(tr("Refresh after connecting the browser extension. Tabs with unknown protection stay open."))
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup(tr("Connection details")) { Text(tr(hint)).font(.caption).textSelection(.enabled) }
                    }.padding(12).glass(radius: 12)
                }
                if task == .organize {
                    ScrollView {
                        NativeTabOrganizerView(app: model.app, pages: model.pages, nativeGroups: model.inventory?.nativeGroups ?? [],
                                               working: $model.busy,
                                               previewOnly: model.isPreview, refresh: model.refresh)
                    }
                } else { archiveTabs }
            }
        }.padding(24)
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

    var scopePicker: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { scopeControls; Spacer(); scopeCount }.frame(minWidth: 600)
            VStack(alignment: .leading, spacing: 8) { scopeControls; scopeCount }
        }.padding(12).glass(radius: 12)
    }
    var scopeControls: some View {
        HStack {
            Text(tr("Scope")).font(.callout.weight(.medium))
            Picker(tr("Scope"), selection: Binding(get: { model.allWindows }, set: { model.selectAllWindows($0) })) {
                Text(tr("One window")).tag(false); Text(tr("All Chrome windows")).tag(true)
            }.labelsHidden().frame(width: 150)
            if !model.allWindows, let inventory = model.inventory {
                Picker(tr("Window"), selection: Binding(get: { model.window ?? inventory.pages.first?.tab.window ?? 0 }, set: { model.selectWindow($0) })) {
                    ForEach(Array(Set(inventory.pages.map { $0.tab.window })).sorted(), id: \.self) { id in Text(model.windowLabel(id)).tag(id) }
                }.labelsHidden().frame(maxWidth: 230)
            }
        }
    }
    var scopeCount: some View {
        Text(tr("%1$@ tabs · %2$@ protected", String(model.pages.count), String(model.pages.filter { !$0.canArchive }.count)))
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Label(tr("Put unused tabs away for later"), systemImage: "archivebox").font(.headline)
                Text(tr("Save their links on this Mac, then close the tabs. Reopen them from Saved for later when you need them."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(tr("Form input, scroll positions and sign-in state are not saved."))
                    .font(.caption).foregroundStyle(.orange)
                ViewThatFits(in: .horizontal) {
                    HStack { archiveName; archivePrimary }.frame(minWidth: 580)
                    VStack(alignment: .leading, spacing: 8) { archiveName; archivePrimary }
                }
                if model.candidates.isEmpty && !model.busy {
                    Text(tr("No tabs can be safely closed in this scope. Protected tabs are kept."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(16).glass(radius: 14)
            HStack {
                TextField(tr("Search title, website or category"), text: $search).textFieldStyle(.roundedBorder)
                Menu(tr("Select tabs")) {
                    Button(tr("Select only closable tabs")) { model.selected = Set(model.candidates.map(\.id)) }
                    Button(tr("Clear selection")) { model.selected = [] }
                }.disabled(model.busy)
            }
            if !model.selected.isEmpty {
                HStack {
                    Text(tr("%1$@ selected · %2$@ can be saved and closed", String(model.chosen.count), String(eligibleSelection.count)))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("Clear selection")) { model.selected = [] }.buttonStyle(.link)
                }
            }
            DisclosureGroup(tr("Optional: organize this list with your own categories"), isExpanded: $categorizing) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("These categories only change the list in Thermo. They do not change Chrome groups or close any tabs."))
                        .font(.caption).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack { categoryName; categoryActions }.frame(minWidth: 620)
                        VStack(alignment: .leading, spacing: 8) { categoryName; categoryActions }
                    }
                }.padding(.top, 6)
            }.font(.caption)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groupNames, id: \.self) { group in groupRow(group) }
                    if filtered.isEmpty {
                        Text(search.isEmpty ? tr("No tabs in this scope. Choose another window or refresh.") : tr("No matching pages."))
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                }
            }
        }
    }
    var archiveName: some View { TextField(tr("Name this saved set (optional)"), text: $batchName).textFieldStyle(.roundedBorder) }
    var archivePrimary: some View {
        Button { requestArchive(model.selected.isEmpty ? model.candidates : eligibleSelection) } label: {
            Label(tr("Review saving %1$@ tabs", String(model.selected.isEmpty ? model.candidates.count : eligibleSelection.count)), systemImage: "archivebox")
        }.buttonStyle(PillButtonStyle(prominent: true)).disabled(model.busy || (model.selected.isEmpty ? model.candidates : eligibleSelection).isEmpty)
    }
    var categoryName: some View { TextField(tr("Category name for selected tabs"), text: $groupName).textFieldStyle(.roundedBorder) }
    var categoryActions: some View {
        HStack {
            Button(tr("Apply category")) { model.group(groupName) }
                .disabled(model.chosen.isEmpty || groupName.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
            Button(tr("Reset this list by website")) { model.group(nil) }.disabled(model.busy || model.pages.isEmpty)
        }
    }
    func groupRow(_ name: String) -> some View {
        let pages = filtered.filter { $0.group == name }
        let closable = pages.filter(\.canArchive)
        return DisclosureGroup {
            ForEach(pages) { page in
                HStack(alignment: .top, spacing: 10) {
                    Toggle(isOn: Binding(get: { model.selected.contains(page.id) }, set: { if $0 { model.selected.insert(page.id) } else { model.selected.remove(page.id) } })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(page.tab.title.isEmpty ? page.tab.url : page.tab.title).lineLimit(2)
                            Text(TabWorkspace.site(page.tab.url)).font(.caption).foregroundStyle(.secondary)
                        }
                    }.toggleStyle(.checkbox).font(.callout).disabled(model.busy || (!page.canArchive && !categorizing))
                    Spacer()
                    if model.allWindows { Text(model.windowLabel(page.tab.window)).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    if let reason = page.protectedReason { Label(tr(reason), systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }.padding(.vertical, 5)
            }
        } label: {
            HStack {
                Label(name, systemImage: "folder").font(.callout.weight(.semibold)).foregroundStyle(.cyan).lineLimit(1)
                Text(tr("%1$@ tabs", String(pages.count))).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if closable.isEmpty {
                    Label(tr("All tabs kept"), systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(tr("Save and close %1$@", String(closable.count))) { requestArchive(closable, name: name) }
                        .buttonStyle(PillButtonStyle()).disabled(model.busy)
                }
            }
        }.padding(12).glass(radius: 12)
    }
    var savedGroups: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if model.saved.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "archivebox").font(.system(size: 32)).foregroundStyle(.cyan)
                        Text(tr("Nothing saved for later yet")).font(.headline)
                        Text(tr("Use Save and close to keep links here before putting unused tabs away."))
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button(tr("Choose tabs to save")) { task = .archive }.buttonStyle(PillButtonStyle(prominent: true))
                    }.frame(maxWidth: .infinity).padding(.vertical, 48)
                }
                ForEach(model.saved) { record in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(record.name, systemImage: "archivebox.fill").font(.headline).lineLimit(1)
                            Spacer()
                            Button(tr("Reopen %1$@ tabs", String(record.remaining))) { plan = Plan(archive: record) }
                                .buttonStyle(PillButtonStyle(prominent: record.remaining > 0)).disabled(record.remaining == 0 || model.busy)
                        }
                        Text(record.saved, style: .date).font(.caption).foregroundStyle(.secondary)
                        Text(tr("%1$@ saved · %2$@ closed · %3$@ not yet reopened", String(record.entries.count), String(record.closed), String(record.remaining)))
                            .font(.caption).foregroundStyle(.secondary)
                        if record.remaining == 0 { Text(tr("No confirmed closed tabs remain to reopen.")).font(.caption).foregroundStyle(.secondary) }
                        DisclosureGroup(tr("Links, results and reopening options")) {
                            Menu(tr("Reopen in a specific window")) {
                                ForEach(Array(Set((model.inventory?.pages ?? []).map { $0.tab.window })).sorted(), id: \.self) { window in
                                    Button(model.windowLabel(window)) { plan = Plan(archive: record, destinationWindow: window) }
                                }
                            }.disabled(record.remaining == 0 || model.busy)
                            ForEach(record.entries) { entry in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.page.tab.title).font(.callout)
                                        Link(entry.page.tab.url, destination: URL(string: entry.page.tab.url) ?? URL(string: "about:blank")!).font(.caption).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(tr(entry.restoreState ?? entry.status)).font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 5)
                            }
                        }.font(.caption)
                    }.padding(16).glass(radius: 14)
                }
            }
        }
    }
}
