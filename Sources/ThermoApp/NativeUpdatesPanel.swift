import AgentCore
import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

@MainActor
final class NativeUpdatesModel: ObservableObject {
    @Published private(set) var sources: [NativeUpdateSource] = []
    @Published private(set) var discoveryReport: NativeUpdateSourcesReport?
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var checking: Set<String> = []
    @Published private(set) var results: [String: NativeUpdateCheck] = [:]
    @Published private(set) var message: String?
    @Published private(set) var installing = false
    @Published private(set) var installResult: NativeInstallResult?
    @Published private(set) var recoveryRecords: [NativeUpdateReceipt] = []
    @Published private(set) var recoveryBackups: [NativeBackupUsage] = []
    @Published var backupRemovalReview: NativeBackupRemovalReview?
    @Published private(set) var backupCleanupResult: CleanResult?
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
    private let read: @Sendable (ScanCancellation) -> NativeUpdateSourcesReport
    private let checker: @Sendable (NativeUpdateSource) async -> NativeUpdateCheck
    private let installer: @Sendable (NativeUpdateCheck) async -> NativeInstallResult
    private let restorer: @Sendable (NativeUpdateReceipt) -> NativeInstallResult
    private let recoveryReader: @Sendable () -> NativeRecoveryReport
    private let backupReviewer: @Sendable (NativeUpdateReceipt) throws -> NativeBackupRemovalReview
    private let backupRemover: @Sendable (NativeBackupRemovalReview) -> CleanResult

    init(read: (@Sendable (ScanCancellation) -> [NativeUpdateSource])? = nil,
         discovery: (@Sendable (ScanCancellation) -> NativeUpdateSourcesReport)? = nil,
         checker: @escaping @Sendable (NativeUpdateSource) async -> NativeUpdateCheck = { await NativeAppUpdates.check($0) },
         installer: @escaping @Sendable (NativeUpdateCheck) async -> NativeInstallResult = { await NativeUpdateTransaction.installAvailable($0) },
         restorer: @escaping @Sendable (NativeUpdateReceipt) -> NativeInstallResult = { NativeUpdateTransaction.restore($0.id, review: $0) },
         backupReviewer: @escaping @Sendable (NativeUpdateReceipt) throws -> NativeBackupRemovalReview = { try NativeUpdateTransaction.reviewBackupRemoval($0) },
         backupRemover: @escaping @Sendable (NativeBackupRemovalReview) -> CleanResult = { NativeUpdateTransaction.trashBackup($0) },
         recoveryReader: @escaping @Sendable () -> NativeRecoveryReport = { NativeUpdateTransaction.recovery() }) {
        self.read = discovery ?? { token in
            if let read { return .init(sources: read(token), cancelled: token.isCancelled) }
            return NativeAppUpdates.sourceReport(cancellation: token)
        }
        self.checker = checker; self.installer = installer; self.restorer = restorer; self.recoveryReader = recoveryReader
        self.backupReviewer = backupReviewer; self.backupRemover = backupRemover
    }

    func load(preservingMessage: Bool = false) {
        guard !installing else { return }
        if loadInFlight { pendingLoad = true; loading = true; return }
        generation = UUID()
        for task in tasks.values { task.cancel() }
        pending = []; results = [:]; if !preservingMessage { message = nil }; loading = true; loaded = false; discoveryReport = nil; loadInFlight = true
        let token = ScanCancellation(); loadToken = token
        let read = self.read
        Task.detached(priority: .utility) {
            let found = read(token)
            await MainActor.run {
                self.loadInFlight = false
                let pending = self.pendingLoad; self.pendingLoad = false
                if self.loadToken === token, !token.isCancelled {
                    self.sources = found.sources; self.discoveryReport = found; self.loading = false; self.loaded = true; self.loadToken = nil
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
                self.recoveryRecords = report.records; self.recoveryBackups = report.backups ?? []
                self.preservedWorkspaces = report.workspaces ?? []; self.recoveryIssues = report.issues
            }
        }
    }

    var allPreservedWorkspaces: [NativePreservedWorkspace] {
        var records = preservedWorkspaces
        for entry in installResult?.workspacePreservations ?? [] where !records.contains(where: { $0.id == entry.id }) { records.append(entry.workspace) }
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

    func inspectBackup(_ record: NativeUpdateReceipt) {
        do { NSWorkspace.shared.activateFileViewerSelecting([try NativeUpdateTransaction.backupURL(record)]) }
        catch { message = tr(error.localizedDescription) }
    }

    func reviewBackupRemoval(_ record: NativeUpdateReceipt) {
        guard !installing, !AppModels.shared.softwareUpdates.working else { message = tr("Wait for the current update or checks to finish"); return }
        stopAll(); installing = true; backupRemovalReview = nil; backupCleanupResult = nil
        let reviewer = backupReviewer
        Task.detached(priority: .utility) {
            do {
                let review = try reviewer(record)
                await MainActor.run { self.installing = false; self.backupRemovalReview = review }
            } catch {
                let reason = error.localizedDescription
                await MainActor.run { self.installing = false; self.message = tr(reason) }
            }
        }
    }

    func trashBackup(_ review: NativeBackupRemovalReview) {
        guard !installing, !AppModels.shared.softwareUpdates.working else { message = tr("Wait for the current update or checks to finish"); return }
        stopAll(); installing = true; exitRequested = false; backupRemovalReview = nil
        recoveryGeneration = UUID(); pendingRecovery = false; recoveryLoaded = false
        let remove = backupRemover
        Task.detached(priority: .utility) {
            let result = remove(review)
            await MainActor.run {
                self.backupCleanupResult = result
                self.message = result.failed.isEmpty && !result.removed.isEmpty
                    ? tr("Backup moved to the Trash. Restore it from History before rolling back this app.")
                    : result.failed.values.sorted().map { tr($0) }.joined(separator: "\n")
                self.installing = false; self.refreshRecovery(); self.load(preservingMessage: true)
            }
        }
    }

    func restore(_ record: NativeUpdateReceipt) {
        guard !installing, !AppModels.shared.softwareUpdates.working else { message = tr("Wait for the current update or checks to finish"); return }
        stopAll(); installing = true; exitRequested = false
        recoveryGeneration = UUID(); pendingRecovery = false
        recoveryLoaded = false
        let restore = self.restorer
        Task.detached(priority: .utility) {
            let result = restore(record)
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
    /// One app: its icon, version and where updates come from, then what can be done.
    func sourceRow(_ source: NativeUpdateSource) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: source.app.path)).resizable().frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(source.app.name).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text((source.app.version ?? "–") + (source.installedBuild.flatMap { $0 == source.app.version ? nil : " (" + $0 + ")" } ?? ""))
                            .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        StatusTag(text: source.kind == "sparkle" ? "Sparkle" : source.kind == "appStore" ? "App Store" : tr("Other apps"))
                    }
                    Text(source.feedHost ?? (source.kind == "appStore" ? "App Store" : tr("No app-declared update feed")))
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).textSelection(.enabled)
                        .help(FSPath.tilde(source.app.path))
                }
                Spacer(minLength: Theme.Space.s)
                if model.checking.contains(source.id) { ProgressView().controlSize(.small) }
                if source.canCheck {
                    if model.checking.contains(source.id) {
                        Button(tr("Stop")) { model.stop(source) }.buttonStyle(PillButtonStyle()).controlSize(.small)
                    } else {
                        Button(tr("Check")) { model.check(source) }.buttonStyle(PillButtonStyle()).controlSize(.small)
                            .disabled(model.loading || model.installing || model.checking.count >= NativeUpdatesModel.maximumChecks)
                    }
                }
                if source.app.inventoryIdentity == nil {
                    Button(tr("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.app.path)]) }
                        .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(model.loading || model.installing)
                } else {
                    Button(source.kind == "appStore" ? tr("App Store") : tr("Open app")) { model.openUpdater(source) }
                        .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(model.loading || model.installing)
                }
            }
            if let blocked = source.blocked { Text(tr(blocked)).font(Theme.caption).foregroundStyle(Theme.caution).padding(.leading, 40) }
            if let result = model.results[source.id] {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    if let release = result.release {
                        Text(tr("Feed candidate: %1$@ (build %2$@)", release.version, release.build)).font(Theme.secondary.monospacedDigit()).foregroundStyle(Theme.textPrimary)
                    }
                    Text(tr(result.message)).font(Theme.caption)
                        .foregroundStyle(result.status == "failed" || result.status == "changed" ? Theme.caution : Theme.textSecondary)
                    if result.status == "available" {
                        if let why = NativeUpdateTransaction.installationRefusal(result) {
                            Text(tr(why)).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        } else {
                            Button(tr("Install in Thermo…")) { installing = result }.buttonStyle(PillButtonStyle(prominent: true)).controlSize(.small)
                                .disabled(model.installing || model.loading || !model.checking.isEmpty)
                        }
                    }
                    if !result.skipped.isEmpty {
                        DisclosureGroup {
                            ForEach(result.skipped, id: \.self) { Text(tr($0)).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
                        } label: {
                            Text(tr("Feed entries not selected")).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .padding(.leading, 40)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, Theme.Space.m).padding(.vertical, 10)
        .hoverHighlight()
        .animation(Theme.standard, value: model.results[source.id] != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if let message = model.message { NoticeBanner(text: message) }
                if let issue = model.installResult?.cleanupIssue, model.installResult?.workspacePreservations.isEmpty == true {
                    Text(tr(issue)).font(Theme.secondary).foregroundStyle(Theme.caution)
                }
                ForEach(model.installResult?.workspacePreservations ?? []) { entry in
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(tr(entry.workspace.reason)).font(Theme.secondary).foregroundStyle(Theme.caution)
                        Text(entry.workspace.path).font(Theme.mono).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                        if !entry.recorded {
                            Text(tr("The workspace recovery record could not be saved; keep this path")).font(Theme.caption).foregroundStyle(Theme.caution)
                        }
                        Button(tr("Inspect preserved update files")) { model.inspect(entry.workspace) }
                            .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(model.installing)
                    }
                    .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.caution.opacity(0.07)))
                }
                if model.exitRequested && model.installing {
                    Text(tr("Wait for installation and verification to finish before quitting Thermo.")).font(Theme.secondary).foregroundStyle(Theme.caution)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(spacing: Theme.Space.s) {
                        SearchField(text: $search)
                        InfoButton(text: tr("Discovery stays on this Mac. Check contacts only the selected app's declared feed; no system profile or cookies are sent.")
                                   + "\n\n" + tr("Signed ZIP and DMG app updates can be installed here with recovery; other formats use the original updater."))
                    }
                    if let report = model.discoveryReport, !report.complete {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                                    Text(tr(issue.message) + " · " + FSPath.tilde(issue.path)).font(Theme.caption).foregroundStyle(Theme.textTertiary).textSelection(.enabled)
                                }
                                if report.issuesTruncated { Text(tr("More discovery issues were omitted.")).font(Theme.caption).foregroundStyle(Theme.caution) }
                            }.padding(.top, Theme.Space.xs)
                        } label: {
                            Label(tr("Application discovery is incomplete. Listed entries may have identity or read issues; missing rows do not prove that no other updates exist."), systemImage: "exclamationmark.triangle")
                                .font(Theme.secondary).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                        .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.caution.opacity(0.07)))
                    }
                    let rows = visible
                    if !model.loaded && rows.isEmpty {
                        SkeletonList(rows: 6)
                    } else if rows.isEmpty {
                        InspectorPanel {
                            EmptyState(symbol: "magnifyingglass", title: tr(model.sources.isEmpty
                                ? (model.discoveryReport?.complete == true ? "No app update sources were found in the inspected locations." : "No app sources could be confirmed; discovery is incomplete.")
                                : "No matching items"))
                        }
                    } else {
                        RowList(items: rows, inset: 56) { source in sourceRow(source) }
                    }
                }
                .padding(.horizontal, Theme.pagePadding).padding(.top, Theme.Space.s).padding(.bottom, Theme.Space.xl)
                .frame(maxWidth: Theme.pageWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ActionBar {
                Button(tr("Recovery")) { model.showRecovery = true }.buttonStyle(PillButtonStyle())
                if model.loading { ProgressView().controlSize(.small) }
                Spacer()
                if model.installing { ProgressView().controlSize(.small) }
                else if !model.checking.isEmpty {
                    Button(tr("Stop checks")) { model.stopAll() }.buttonStyle(PillButtonStyle())
                } else {
                    Button(tr("Refresh")) { model.load() }.buttonStyle(PillButtonStyle()).disabled(model.loading)
                    Button(tr("Check listed feeds…")) { confirmingAll = true }.buttonStyle(PillButtonStyle(prominent: true))
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
            if let batch = model.backupCleanupResult?.trashBatchID {
                Text(tr("Trash batch: %1$@", batch)).font(.caption).textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.recoveryIssues, id: \.self) { Text(tr($0)).font(.callout).foregroundStyle(.orange) }
                    ForEach(model.recoveryRecords) { record in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.target).font(.caption).textSelection(.enabled)
                            Text(record.previousVersion + " → " + record.installedVersion + " · " + tr(record.phase)).font(.caption).foregroundStyle(.secondary)
                            Text(record.backup).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if let usage = model.recoveryBackups.first(where: { $0.id == record.id }) {
                                Text(usage.allocatedBytes.map {
                                    tr(usage.complete ? "Preserved app allocated usage: %1$@" : "Preserved app allocated usage: at least %1$@", ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))
                                } ?? tr("Preserved app size is unknown")).font(.caption)
                                if let issue = usage.issue { Text(tr(issue)).font(.caption).foregroundStyle(.orange) }
                            } else {
                                Text(tr("Preserved app size is unknown")).font(.caption)
                            }
                            Button(tr("Reveal preserved app in Finder")) { model.inspectBackup(record) }.disabled(model.installing)
                            Button(tr("Move backup to the Trash…")) { model.reviewBackupRemoval(record) }
                                .disabled(model.installing || !["installed", "restored", "rolledBack"].contains(record.phase))
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
            .sheet(item: $model.backupRemovalReview) { review in
                ConfirmSheet(title: tr("Move this update backup to the Trash?"), summary: tr("Backup version: %1$@", review.backupVersion),
                    destructive: true, heading: tr("Files to move to the Trash"),
                    lines: [review.receipt.backup, tr("Current app kept: %1$@", review.receipt.target), tr("Current version kept: %1$@", review.currentVersion),
                            tr(review.sizeComplete ? "Preserved app allocated usage: %1$@" : "Preserved app allocated usage: at least %1$@", ByteCountFormatter.string(fromByteCount: review.allocatedBytes, countStyle: .file))],
                    footnote: tr("Restore the backup from History before rolling back this app. Space is not freed until the Trash is emptied."),
                    confirmTitle: tr("Move to Trash"), confirm: { model.trashBackup(review) }, cancel: { model.backupRemovalReview = nil })
            }
    }
}
