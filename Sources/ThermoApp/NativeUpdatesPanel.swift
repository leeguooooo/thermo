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
    @Published private(set) var installing = false
    @Published private(set) var installResult: NativeInstallResult?
    @Published private(set) var recoveryRecords: [NativeUpdateReceipt] = []
    @Published private(set) var preservedWorkspaces: [NativePreservedWorkspace] = []
    @Published private(set) var recoveryIssues: [String] = []
    @Published private(set) var recoveryLoading = false
    private var recoveryLoaded = false
    @Published var showRecovery = false
    @Published var exitRequested = false
    static let maximumChecks = 4
    private var generation = UUID()
    private var loadInFlight = false, pendingLoad = false
    private var recoveryInFlight = false, pendingRecovery = false
    private var recoveryGeneration = UUID()
    private var loadToken: ScanCancellation?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var pending: [NativeUpdateSource] = []
    private let read: @Sendable (ScanCancellation) -> [NativeUpdateSource]
    private let checker: @Sendable (NativeUpdateSource) async -> NativeUpdateCheck
    private let installer: @Sendable (NativeUpdateCheck) async -> NativeInstallResult
    private let restorer: @Sendable (String) -> NativeInstallResult
    private let recoveryReader: @Sendable () -> NativeRecoveryReport

    init(read: @escaping @Sendable (ScanCancellation) -> [NativeUpdateSource] = { token in
        NativeAppUpdates.sources(apps: AppUninstaller.installed(cancellation: token))
    }, checker: @escaping @Sendable (NativeUpdateSource) async -> NativeUpdateCheck = { await NativeAppUpdates.check($0) },
         installer: @escaping @Sendable (NativeUpdateCheck) async -> NativeInstallResult = { await NativeUpdateTransaction.installAvailable($0) },
         restorer: @escaping @Sendable (String) -> NativeInstallResult = { NativeUpdateTransaction.restore($0) },
         recoveryReader: @escaping @Sendable () -> NativeRecoveryReport = { NativeUpdateTransaction.recovery() }) {
        self.read = read; self.checker = checker; self.installer = installer; self.restorer = restorer; self.recoveryReader = recoveryReader
    }

    func load(preservingMessage: Bool = false) {
        guard !installing else { return }
        if loadInFlight { pendingLoad = true; loading = true; return }
        generation = UUID()
        for task in tasks.values { task.cancel() }
        pending = []; results = [:]; if !preservingMessage { message = nil }; loading = true; loaded = false; loadInFlight = true
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
        guard !loading, !installing, source.canCheck, !checking.contains(source.id), checking.count < Self.maximumChecks else { return }
        start(source)
    }

    func checkAll(_ sources: [NativeUpdateSource]) {
        guard !loading, !installing else { return }
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
        recoveryGeneration = UUID(); pendingRecovery = false
        recoveryLoading = false; recoveryLoaded = false
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

    func install(_ reviewed: NativeUpdateCheck) {
        guard !installing, !loading, checking.isEmpty, !AppModels.shared.softwareUpdates.working else {
            message = tr("Wait for the current update or checks to finish"); return
        }
        installing = true; exitRequested = false
        recoveryGeneration = UUID(); pendingRecovery = false
        recoveryLoaded = false
        let installer = self.installer
        Task.detached(priority: .utility) {
            let result = await installer(reviewed)
            await MainActor.run {
                self.installResult = result; self.message = tr(result.message)
                self.installing = false
                self.refreshRecovery()
                self.load(preservingMessage: true)
            }
        }
    }

    func refreshRecovery() {
        guard !installing else { pendingRecovery = true; recoveryLoading = true; return }
        if recoveryInFlight { pendingRecovery = true; recoveryLoading = true; return }
        recoveryInFlight = true; pendingRecovery = false
        recoveryLoading = true
        let token = recoveryGeneration
        let recovery = self.recoveryReader
        Task.detached(priority: .utility) {
            let report = recovery()
            await MainActor.run {
                self.recoveryInFlight = false
                if self.pendingRecovery { self.pendingRecovery = false; self.refreshRecovery(); return }
                guard self.recoveryGeneration == token else { self.recoveryLoading = false; return }
                self.recoveryLoading = false; self.recoveryLoaded = true
                self.recoveryRecords = report.records; self.preservedWorkspaces = report.workspaces ?? []; self.recoveryIssues = report.issues
            }
        }
    }

    var allPreservedWorkspaces: [NativePreservedWorkspace] {
        var records = preservedWorkspaces
        if let record = installResult?.preservedWorkspace, !records.contains(where: { $0.id == record.id }) { records.append(record) }
        return records
    }

    var recoveryIsConfirmedEmpty: Bool {
        recoveryLoaded && !recoveryLoading && recoveryRecords.isEmpty && allPreservedWorkspaces.isEmpty && recoveryIssues.isEmpty
    }

    func inspect(_ record: NativePreservedWorkspace) {
        do { NSWorkspace.shared.open(try NativeUpdateTransaction.preservedWorkspaceURL(record)) }
        catch { message = tr(error.localizedDescription) }
    }

    func openRecoveryFolder() {
        do { NSWorkspace.shared.open(try NativeUpdateTransaction.recoveryFolderURL()) }
        catch { message = tr(error.localizedDescription) }
    }

    func restore(_ record: NativeUpdateReceipt) {
        guard !installing, !AppModels.shared.softwareUpdates.working else { message = tr("Wait for the current update or checks to finish"); return }
        stopAll(); installing = true; exitRequested = false
        recoveryGeneration = UUID(); pendingRecovery = false
        recoveryLoaded = false
        let restore = self.restorer
        Task.detached(priority: .utility) {
            let result = restore(record.id)
            await MainActor.run {
                self.installResult = result; self.message = tr(result.message)
                self.installing = false; self.refreshRecovery(); self.load(preservingMessage: true)
            }
        }
    }
}

struct NativeUpdatesPanel: View {
    @ObservedObject var model: NativeUpdatesModel
    @State private var search = ""
    @State private var confirmingAll = false
    @State private var installing: NativeUpdateCheck?
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
            if let issue = model.installResult?.cleanupIssue { Text(tr(issue)).font(.callout).foregroundStyle(.orange) }
            if let workspace = model.installResult?.preservedWorkspace {
                Text(workspace.path).font(.caption).textSelection(.enabled)
                if model.installResult?.workspaceRecordSaved == false {
                    Text(tr("The workspace recovery record could not be saved; keep this path")).font(.caption).foregroundStyle(.orange)
                }
                Button(tr("Inspect preserved update files")) { model.inspect(workspace) }.disabled(model.installing)
            }
            if model.exitRequested && model.installing {
                Text(tr("Wait for installation and verification to finish before quitting Thermo.")).font(.callout).foregroundStyle(.orange)
            }
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
                                            .disabled(model.loading || model.installing || model.checking.count >= NativeUpdatesModel.maximumChecks)
                                    }
                                }
                                if source.app.inventoryIdentity == nil {
                                    Button(tr("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.app.path)]) }
                                        .buttonStyle(PillButtonStyle()).disabled(model.loading || model.installing)
                                } else {
                                    Button(source.kind == "appStore" ? tr("App Store") : tr("Open app")) { model.openUpdater(source) }
                                        .buttonStyle(PillButtonStyle()).disabled(model.loading || model.installing)
                                }
                            }
                            if model.checking.contains(source.id) { ProgressView().controlSize(.small) }
                            if let blocked = source.blocked { Text(tr(blocked)).font(.caption).foregroundStyle(.orange) }
                            if let result = model.results[source.id] {
                                if let release = result.release {
                                    Text(tr("Feed candidate: %1$@ (build %2$@)", release.version, release.build)).font(.callout)
                                }
                                Text(tr(result.message)).font(.caption).foregroundStyle(result.status == "failed" || result.status == "changed" ? Color.orange : Color.secondary)
                                if result.status == "available" {
                                    if let why = NativeUpdateTransaction.installationRefusal(result) {
                                        Text(tr(why)).font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Button(tr("Install in Thermo…")) { installing = result }.buttonStyle(PillButtonStyle())
                                            .disabled(model.installing || model.loading || !model.checking.isEmpty)
                                    }
                                }
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
                Text(tr("Signed ZIP and DMG app updates can be installed here with recovery; other formats use the original updater."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Recovery")) { model.showRecovery = true }.buttonStyle(PillButtonStyle())
                if model.installing { ProgressView().controlSize(.small) }
                else if !model.checking.isEmpty {
                    Button(tr("Stop checks")) { model.stopAll() }.buttonStyle(PillButtonStyle())
                } else {
                    Button(tr("Refresh")) { model.load() }.buttonStyle(PillButtonStyle()).disabled(model.loading)
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
        .sheet(item: $installing) { checked in
            ConfirmSheet(title: tr("Install this native update?"),
                summary: checked.source.app.name + " → " + (checked.release?.version ?? ""), destructive: false,
                heading: tr("Applications to replace"), lines: [checked.source.app.path],
                footnote: tr("The archive, publisher, version and architecture are checked before replacement. Quit the app first. The old app is preserved for recovery."),
                confirmTitle: tr("Install"), confirmEnabled: !model.installing,
                confirm: { installing = nil; model.install(checked) }, cancel: { installing = nil })
        }
        .sheet(isPresented: $model.showRecovery) { NativeUpdateRecoveryView(model: model) }
    }
}

struct NativeUpdateRecoveryView: View {
    @ObservedObject var model: NativeUpdatesModel
    @Environment(\.dismiss) private var dismiss
    @State private var restoring: NativeUpdateReceipt?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Native update recovery")).font(.headline)
            Text(tr("Version records can restore unchanged apps. Preserved preparation files are available for inspection.")).font(.callout).foregroundStyle(.secondary)
            if let message = model.message { Text(message).font(.callout).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.recoveryIssues, id: \.self) { Text(tr($0)).font(.callout).foregroundStyle(.orange) }
                    ForEach(model.recoveryRecords) { record in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.target).font(.caption).textSelection(.enabled)
                            Text(record.previousVersion + " → " + record.installedVersion + " · " + tr(record.phase)).font(.caption).foregroundStyle(.secondary)
                            Button(tr("Restore previous app…")) { restoring = record }.disabled(model.installing || record.phase == "restored" || record.phase == "rolledBack")
                        }
                    }
                    ForEach(model.allPreservedWorkspaces) { workspace in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(tr("Preserved update files")).font(.headline)
                            Text(workspace.target).font(.caption).textSelection(.enabled)
                            Text(tr(workspace.reason)).font(.callout).foregroundStyle(.orange)
                            Text(workspace.path).font(.caption).textSelection(.enabled)
                            Button(tr("Inspect preserved update files")) { model.inspect(workspace) }.disabled(model.installing)
                        }
                    }
                    if model.recoveryIsConfirmedEmpty { Text(tr("No native update recovery records")).foregroundStyle(.secondary) }
                }
            }.frame(minHeight: 180, maxHeight: 300)
            HStack {
                Button(tr("Open recovery folder")) { model.openRecoveryFolder() }.disabled(model.installing)
                if model.installing || model.recoveryLoading { ProgressView().controlSize(.small) }
                Spacer(); Button(tr("Close")) { dismiss() }
            }
        }.padding(20).frame(width: 520).onAppear { model.refreshRecovery() }
            .sheet(item: $restoring) { record in
                ConfirmSheet(title: tr("Restore the previous app?"), summary: record.installedVersion + " → " + record.previousVersion,
                    destructive: false, heading: tr("Applications to replace"), lines: [record.target, record.backup],
                    footnote: tr("Quit the app first. Recovery refuses changed applications and preserves both versions."),
                    confirmTitle: tr("Restore"), confirm: { restoring = nil; model.restore(record) }, cancel: { restoring = nil })
            }
    }
}
