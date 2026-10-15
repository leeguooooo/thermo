import AgentCore
import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

@MainActor
final class NativeUpdatesModel: ObservableObject {
    @Published private(set) var sources: [NativeUpdateSource] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var checking: Set<String> = []
    @Published private(set) var results: [String: NativeUpdateCheck] = [:]
    @Published private(set) var message: String?
    static let maximumChecks = 4
    private var generation = UUID()
    private var loadInFlight = false, pendingLoad = false
    private var loadToken: ScanCancellation?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var pending: [NativeUpdateSource] = []
    private let read: @Sendable (ScanCancellation) -> [NativeUpdateSource]
    private let checker: @Sendable (NativeUpdateSource) async -> NativeUpdateCheck

    init(read: @escaping @Sendable (ScanCancellation) -> [NativeUpdateSource] = { token in
        NativeAppUpdates.sources(apps: AppUninstaller.installed(cancellation: token))
    }, checker: @escaping @Sendable (NativeUpdateSource) async -> NativeUpdateCheck = { await NativeAppUpdates.check($0) }) {
        self.read = read; self.checker = checker
    }

    func load() {
        if loadInFlight { pendingLoad = true; loading = true; return }
        generation = UUID()
        for task in tasks.values { task.cancel() }
        pending = []; results = [:]; message = nil; loading = true; loaded = false; loadInFlight = true
        let token = ScanCancellation(); loadToken = token
        let read = self.read
        Task.detached(priority: .utility) {
            let found = read(token)
            await MainActor.run {
                self.loadInFlight = false
                let pending = self.pendingLoad; self.pendingLoad = false
                if self.loadToken === token, !token.isCancelled {
                    self.sources = found; self.loading = false; self.loaded = true; self.loadToken = nil
                }
                if pending { self.load() }
            }
        }
    }

    func check(_ source: NativeUpdateSource) {
        guard !loading, source.canCheck, !checking.contains(source.id), checking.count < Self.maximumChecks else { return }
        start(source)
    }

    func checkAll(_ sources: [NativeUpdateSource]) {
        guard !loading else { return }
        var queued = Set(pending.map(\.id)).union(checking)
        pending += sources.filter { $0.canCheck && queued.insert($0.id).inserted }
        pump()
    }

    private func pump() {
        while !loading, checking.count < Self.maximumChecks, let index = pending.firstIndex(where: { !checking.contains($0.id) }) {
            start(pending.remove(at: index))
        }
    }

    private func start(_ source: NativeUpdateSource) {
        let token = generation, checker = self.checker
        checking.insert(source.id)
        tasks[source.id] = Task.detached(priority: .utility) {
            let result = await checker(source)
            await MainActor.run {
                self.tasks[source.id] = nil
                self.checking.remove(source.id)
                if self.generation == token {
                    var displayed = result
                    if Task.isCancelled {
                        displayed.status = "cancelled"; displayed.message = "Update check stopped"; displayed.release = nil
                    }
                    self.results[source.id] = displayed
                }
                self.pump()
            }
        }
    }

    func retire() {
        generation = UUID(); pendingLoad = false; pending = []
        loadToken?.cancel(); loadToken = nil; loading = false
        // Keep slots reserved until cancelled workers actually return.
        for task in tasks.values { task.cancel() }
    }

    func stop(_ source: NativeUpdateSource) { tasks[source.id]?.cancel() }

    func stopAll() {
        pending = []
        for task in tasks.values { task.cancel() }
    }

    func openUpdater(_ source: NativeUpdateSource) {
        guard NativeAppUpdates.unchanged(source, requireFeed: false) else {
            message = tr(source.blocked ?? "The app changed since the inventory; refresh the app list and review again"); return
        }
        if source.kind == "appStore" {
            NSWorkspace.shared.open(URL(string: "macappstore://showUpdates")!)
            message = tr("Continue in App Store updates")
            return
        }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: source.app.path), configuration: .init()) { _, error in
            DispatchQueue.main.async {
                self.message = tr(error == nil ? "Check for updates in this app or on its official website" : "Could not open this app; open it from Finder")
            }
        }
    }
}

struct NativeUpdatesPanel: View {
    @ObservedObject var model: NativeUpdatesModel
    @State private var search = ""
    @State private var confirmingAll = false
    private var visible: [NativeUpdateSource] {
        model.sources.filter { search.isEmpty || ($0.app.name + " " + ($0.app.bundleID ?? "")).localizedCaseInsensitiveContains(search) }
            .sorted { ($0.kind == "sparkle" ? 0 : $0.kind == "appStore" ? 1 : 2, $0.app.name) < ($1.kind == "sparkle" ? 0 : $1.kind == "appStore" ? 1 : 2, $1.app.name) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Discovery stays on this Mac. Check contacts only the selected app's declared feed; no system profile or cookies are sent."))
                .font(.callout).foregroundStyle(.secondary)
            TextField(tr("Search"), text: $search).textFieldStyle(.roundedBorder).accessibilityLabel(tr("Search"))
            if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(visible) { source in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.app.name).font(.headline)
                                    Text((source.app.version ?? "–") + (source.installedBuild.flatMap { $0 == source.app.version ? nil : " (" + $0 + ")" } ?? ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(FSPath.tilde(source.app.path)).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                    Text(source.feedHost ?? (source.kind == "appStore" ? "App Store" : tr("No app-declared update feed")))
                                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Spacer()
                                if source.canCheck {
                                    if model.checking.contains(source.id) {
                                        Button(tr("Stop")) { model.stop(source) }.buttonStyle(PillButtonStyle())
                                    } else {
                                        Button(tr("Check")) { model.check(source) }.buttonStyle(PillButtonStyle())
                                            .disabled(model.loading || model.checking.count >= NativeUpdatesModel.maximumChecks)
                                    }
                                }
                                if source.app.inventoryIdentity == nil {
                                    Button(tr("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.app.path)]) }
                                        .buttonStyle(PillButtonStyle()).disabled(model.loading)
                                } else {
                                    Button(source.kind == "appStore" ? tr("App Store") : tr("Open app")) { model.openUpdater(source) }
                                        .buttonStyle(PillButtonStyle()).disabled(model.loading)
                                }
                            }
                            if model.checking.contains(source.id) { ProgressView().controlSize(.small) }
                            if let blocked = source.blocked { Text(tr(blocked)).font(.caption).foregroundStyle(.orange) }
                            if let result = model.results[source.id] {
                                if let release = result.release {
                                    Text(tr("Feed candidate: %1$@ (build %2$@)", release.version, release.build)).font(.callout)
                                }
                                Text(tr(result.message)).font(.caption).foregroundStyle(result.status == "failed" || result.status == "changed" ? Color.orange : Color.secondary)
                                if !result.skipped.isEmpty {
                                    DisclosureGroup(tr("Feed entries not selected")) {
                                        ForEach(result.skipped, id: \.self) { Text(tr($0)).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        }.padding(14).glass(radius: 14)
                    }
                    if !model.loading && visible.isEmpty { Text(tr("No matching items")).foregroundStyle(.secondary) }
                }
            }
            HStack {
                if model.loading { ProgressView().controlSize(.small) }
                Text(tr("Version notices only; finish downloads and installation in the app or on its official website."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Refresh")) { model.load() }.buttonStyle(PillButtonStyle()).disabled(model.loading)
                if !model.checking.isEmpty {
                    Button(tr("Stop checks")) { model.stopAll() }.buttonStyle(PillButtonStyle())
                } else {
                    Button(tr("Check listed feeds…")) { confirmingAll = true }.buttonStyle(PillButtonStyle())
                        .disabled(model.loading || !visible.contains(where: \.canCheck))
                }
            }
        }.onAppear { model.load() }.onDisappear { model.retire() }
        .sheet(isPresented: $confirmingAll) {
            let sources = visible.filter(\.canCheck)
            ConfirmSheet(title: tr("Check these update feeds?"),
                summary: tr("Only the listed feeds will be contacted. No downloads or installation will start."),
                destructive: false, heading: tr("Apps and update servers"),
                lines: sources.map { $0.app.name + " · " + ($0.feedHost ?? "") + "\n" + FSPath.tilde($0.app.path) },
                footnote: tr("Up to four checks run at once. Leaving this page stops pending checks."),
                confirmTitle: tr("Check"), confirmEnabled: !sources.isEmpty,
                confirm: { confirmingAll = false; model.checkAll(sources) }, cancel: { confirmingAll = false })
        }
    }
}
