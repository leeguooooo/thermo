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
    init(app: String) { self.app = app }
    var pages: [TabWorkspace.Page] {
        (inventory?.pages ?? []).filter { allWindows || $0.tab.window == (window ?? inventory?.pages.first?.tab.window) }
    }
    func windowLabel(_ id: Int) -> String {
        var ids: [Int] = []
        for page in inventory?.pages ?? [] where !ids.contains(page.tab.window) { ids.append(page.tab.window) }
        return tr("Window %1$@", String((ids.firstIndex(of: id) ?? 0) + 1))
    }
    var chosen: [TabWorkspace.Page] { pages.filter { selected.contains($0.id) } }
    var candidates: [TabWorkspace.Page] { pages.filter(\.canArchive) }
    func refresh() {
        guard !busy else { return }; busy = true; error = nil
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
        guard !selection.isEmpty, !busy else { return }; busy = true; error = nil
        Task {
            do { try await Task.detached { try TabWorkspace.assign(selection, name: name) }.value }
            catch { self.error = error.localizedDescription }
            busy = false; refresh()
        }
    }
    func archive(_ selection: [TabWorkspace.Page], name: String) {
        guard !busy else { return }; busy = true; error = nil; let app = app
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
        guard !busy else { return }; busy = true; error = nil
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

struct TabWorkspaceView: View {
    @StateObject private var model: TabWorkspaceModel
    @State private var search = ""
    @State private var groupName = ""
    @State private var batchName = ""
    @State private var plan: Plan?
    @State private var savedOnly = false
    struct Plan: Identifiable {
        let id = UUID()
        var pages: [TabWorkspace.Page] = []
        var archive: TabWorkspace.Archive?
        var destinationWindow: Int?
    }
    init(app: String) { _model = StateObject(wrappedValue: TabWorkspaceModel(app: app)) }
    var groupNames: [String] { Array(Set(filtered.map(\.group))).sorted() }
    var filtered: [TabWorkspace.Page] {
        model.pages.filter { search.isEmpty || ($0.tab.title + " " + $0.tab.url + " " + $0.group).localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("Tab groups")).font(.title2.bold())
                    Text(model.app).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(tr("Refresh tabs")) { model.refresh() }.disabled(model.busy)
            }
            Text(tr("Organize native Chrome groups, or save web links before closing tabs and reopen them later. Local Thermo categories are separate from native groups."))
                .font(.callout).foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(.green) }
            Picker(tr("Pages"), selection: $savedOnly) {
                Text(tr("Open tabs")).tag(false)
                Text(tr("Saved groups")).tag(true)
            }.pickerStyle(.segmented)
            if savedOnly { savedGroups } else { openTabs }
        }
        .padding(24)
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: TabQuickAction.notification)) { _ in model.refresh() }
        .onChange(of: model.busy) { busy in
            if !busy && TabQuickAction.requested && model.app == "Google Chrome" {
                TabQuickAction.requested = false
                savedOnly = false; model.allWindows = false; model.window = nil
                if !model.candidates.isEmpty { plan = Plan(pages: model.candidates) }
            }
        }
        .sheet(item: $plan) { value in
            ConfirmSheet(title: value.archive == nil ? tr("Save and close %1$@ tabs?", String(value.pages.count)) : tr("Reopen saved tabs?"),
                         summary: tr("Web links and Thermo groups are saved locally. Unsaved form input and page state cannot be restored."),
                         destructive: value.archive == nil, heading: tr("Selected pages"),
                         lines: value.archive.map { $0.entries.filter { $0.status == "closed" && $0.restoreState == nil }.map { $0.page.tab.title } } ?? value.pages.map { $0.tab.title },
                         footnote: tr("Current, pinned, audible, private and agent tabs are protected. Changed pages are skipped. Unknown results are never automatically retried."),
                         confirmTitle: value.archive == nil ? tr("Save and close") : tr("Reopen"),
                         confirm: {
                             plan = nil
                             if let record = value.archive { model.restore(record, destinationWindow: value.destinationWindow) }
                             else { model.archive(value.pages, name: batchName.isEmpty ? tr("Saved tabs") : batchName) }
                         }, cancel: { plan = nil })
        }
    }
    var openTabs: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeTabOrganizerView(app: model.app, pages: model.pages, working: $model.busy, refresh: model.refresh)
            HStack {
                Toggle(tr("All windows"), isOn: $model.allWindows).toggleStyle(.checkbox)
                if !model.allWindows, let inv = model.inventory {
                    Picker(tr("Window"), selection: Binding(get: { model.window ?? inv.pages.first?.tab.window ?? 0 }, set: { model.window = $0; model.selected = [] })) {
                        ForEach(Array(Set(inv.pages.map { $0.tab.window })).sorted(), id: \.self) { id in Text(model.windowLabel(id)).tag(id) }
                    }.frame(maxWidth: 230)
                }
                Spacer()
                Text(tr("%1$@ tabs · %2$@ can be closed", String(model.pages.count), String(model.candidates.count)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let hint = model.inventory?.hint { Text(tr(hint)).font(.caption).foregroundStyle(.orange) }
            TextField(tr("Search pages"), text: $search).textFieldStyle(.roundedBorder)
            HStack {
                TextField(tr("Thermo category name"), text: $groupName).textFieldStyle(.roundedBorder)
                Button(tr("Set Thermo category")) { model.group(groupName) }.disabled(model.chosen.isEmpty || groupName.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                Button(tr("Group by website")) { model.group(nil) }.disabled(model.busy || model.pages.isEmpty)
            }
            HStack {
                TextField(tr("Saved batch name (optional)"), text: $batchName).textFieldStyle(.roundedBorder)
                Button(tr("Save and close background tabs")) { plan = Plan(pages: model.candidates) }
                    .buttonStyle(.borderedProminent).disabled(model.busy || model.candidates.isEmpty)
            }
            HStack {
                Button(tr("Select background tabs")) { model.selected = Set(model.candidates.map(\.id)) }.disabled(model.busy)
                Button(tr("Clear selection")) { model.selected = [] }
                Spacer()
                Button(tr("Save and close selected")) { plan = Plan(pages: model.chosen.filter(\.canArchive)) }
                    .disabled(model.busy || model.chosen.filter(\.canArchive).isEmpty)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groupNames, id: \.self) { group in groupRow(group) }
                    if filtered.isEmpty { Text(tr("No matching pages.")).foregroundStyle(.secondary) }
                }
            }
        }.disabled(model.busy)
    }
    func groupRow(_ name: String) -> some View {
        let pages = filtered.filter { $0.group == name }
        return DisclosureGroup {
            ForEach(pages) { page in
                HStack(alignment: .top, spacing: 10) {
                    Toggle(isOn: Binding(get: { model.selected.contains(page.id) }, set: { if $0 { model.selected.insert(page.id) } else { model.selected.remove(page.id) } })) {
                        Text(page.tab.title.isEmpty ? page.tab.url : page.tab.title)
                    }.toggleStyle(.checkbox).font(.callout)
                    Spacer()
                    if model.allWindows { Text(model.windowLabel(page.tab.window)).font(.caption).foregroundStyle(.secondary) }
                    if let reason = page.protectedReason { Text(tr(reason)).font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 3)
            }
        } label: {
            HStack {
                Label(name, systemImage: "folder.fill").font(.headline).foregroundStyle(.cyan)
                Text("\(pages.count)").foregroundStyle(.secondary)
                Spacer()
                Button(tr("Save group")) { batchName = name; plan = Plan(pages: pages.filter(\.canArchive)) }
                    .disabled(pages.filter(\.canArchive).isEmpty)
            }
        }.padding(12).glass(radius: 10)
    }
    var savedGroups: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if model.saved.isEmpty { Text(tr("No saved groups yet.")).foregroundStyle(.secondary) }
                ForEach(model.saved) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(record.name, systemImage: "archivebox.fill").font(.headline)
                            Spacer()
                            Text(record.saved, style: .date).font(.caption).foregroundStyle(.secondary)
                            Button(tr("Reopen")) { plan = Plan(archive: record) }.disabled(record.remaining == 0 || model.busy)
                            Menu(tr("Reopen in window")) {
                                ForEach(Array(Set((model.inventory?.pages ?? []).map { $0.tab.window })).sorted(), id: \.self) { window in
                                    Button(model.windowLabel(window)) { plan = Plan(archive: record, destinationWindow: window) }
                                }
                            }.disabled(record.remaining == 0 || model.busy)
                        }
                        Text(tr("%1$@ saved · %2$@ closed · %3$@ awaiting reopening", String(record.entries.count), String(record.closed), String(record.remaining)))
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup(tr("Saved links and results")) {
                            ForEach(record.entries) { entry in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.page.tab.title).font(.callout)
                                        Text(entry.page.group).font(.caption).foregroundStyle(.secondary)
                                        Link(entry.page.tab.url, destination: URL(string: entry.page.tab.url) ?? URL(string: "about:blank")!).font(.caption).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(tr(entry.restoreState ?? entry.status)).font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }
                        }
                    }.padding(14).glass(radius: 12)
                }
            }
        }
    }
}
