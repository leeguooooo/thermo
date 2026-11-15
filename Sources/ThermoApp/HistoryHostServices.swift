import AppKit
import CleanKit
import HistoryFeature
import NativeFeatureAPI
import ModuleKit
import ThermoL10n

/// Assembly adapter: history presentation never owns global quit protection or other features.
@MainActor final class HistoryHostServices: HistoryServices {
    nonisolated private let reader: @Sendable () -> OperationJournal.ReadReport
    nonisolated private let reviewer: @Sendable (String) throws -> TrashRestore
    nonisolated private let restore: @Sendable (String, TrashRestore) throws -> TrashRestore
    private let invalidate: @MainActor ([String]) -> Void
    var journalURL: URL { OperationJournal.url() }

    init(reader: @escaping @Sendable () -> OperationJournal.ReadReport = { OperationJournal.readReport(limit: 300) },
         reviewer: @escaping @Sendable (String) throws -> TrashRestore = { try TrashBatches.restore(id: $0, dryRun: true) },
         restore: @escaping @Sendable (String, TrashRestore) throws -> TrashRestore = { id, review in
             try TrashBatches.restore(id: id, reviewIdentity: review.reviewIdentity,
                 reviewedDestinations: Set(review.items.filter { $0.status == "restored" }.map(\.destination)))
         }, invalidate: @escaping @MainActor ([String]) -> Void = {
             AppModels.shared.nativeFeatures.invalidateAfterRestore($0)
             AppModels.shared.invalidateSpaceAfterRestore($0)
         }) {
        self.reader = reader; self.reviewer = reviewer; self.restore = restore; self.invalidate = invalidate
    }
    nonisolated func read() -> OperationJournal.ReadReport { reader() }
    nonisolated func reviewRestore(batch: String) throws -> TrashRestore { try reviewer(batch) }
    func beginRestore(batch: String, review: TrashRestore) throws -> any HistoryRestoration {
        guard review.id == batch, review.dryRun, review.reviewIdentity != nil,
              review.items.contains(where: { $0.status == "restored" }) else {
            throw NSError(domain: "Thermo.History", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: tr("Restore review is unavailable; review the batch again.")])
        }
        let restore = restore
        return HostHistoryRestoration(restore: { try restore(batch, review) }, invalidate: invalidate)
    }

    enum Destination: Equatable {
        case nativeRecovery, appUpdates, startup, claudeReset, privacy, searchSettings, tabs, trash, reveal(String)
    }
    static func destination(for record: OperationRecord) -> Destination? {
        switch record.undo?.kind {
        case "nativeUpdate", "nativePreparation": return .nativeRecovery
        case nil where record.feature == "apps" && record.action == "update": return .appUpdates
        case "startup": return .startup
        case "claudeReset": return .claudeReset
        case "browserBackup", "timezoneBackup": return .privacy
        case "spotlightShortcut": return .searchSettings
        case "tabArchive", "tabBatch": return .tabs
        case "trash": return .trash
        case "agentBackup", "worktreeBackup": return record.undo.map { .reveal($0.ref) }
        default: return nil
        }
    }
    func followUp(for record: OperationRecord) -> HistoryFollowUp? {
        guard let destination = Self.destination(for: record) else { return nil }
        let title: String, symbol: String?
        switch destination {
        case .trash: title = tr("Open Trash"); symbol = nil
        case .reveal: title = tr("Reveal in Finder"); symbol = "folder"
        default: title = tr("Open"); symbol = nil
        }
        return .init(title: title, symbol: symbol, perform: { Self.perform(destination) })
    }
    static func perform(_ destination: Destination, models: AppModels = .shared,
                        open: @MainActor (MainPage) -> Void = { MainWindow.show($0) }) {
        switch destination {
        case .nativeRecovery:
            let request=NativePresentationRequest(route:.init(BuiltinModuleManifests.apps.id,"updates"),options:["channel":.text("native"),"showRecovery":.boolean(true)])
            if models.nativeFeatures.canPresent(request.route),!models.nativeFeatures.preparePresentation(request){return}
            open(.native(request.route))
        case .appUpdates: open(.native(.init(BuiltinModuleManifests.apps.id,"updates")))
        case .startup: open(.native(.init(BuiltinModuleManifests.apps.id,"startup")))
        case .claudeReset: open(.module(BuiltinModuleManifests.claude.id, "reset"))
        case .privacy: open(.module(BuiltinModuleManifests.claude.id, "privacy"))
        case .searchSettings: LocalSearchPanel.shared.show(settings: true)
        case .tabs: open(.browser("Google Chrome"))
        case .trash: NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
        case .reveal(let path): NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
}

@MainActor private final class HostHistoryRestoration: HistoryRestoration {
    private enum Phase { case pending, running, finished }
    private var phase = Phase.pending
    private var token: UUID?
    private let restore: @Sendable () throws -> TrashRestore
    private let invalidate: @MainActor ([String]) -> Void
    init(restore: @escaping @Sendable () throws -> TrashRestore, invalidate: @escaping @MainActor ([String]) -> Void) {
        self.restore = restore; self.invalidate = invalidate
        token = AppExitGuard.beginRestore()
    }
    deinit {
        if let token { Task { @MainActor in AppExitGuard.endRestore(token) } }
    }
    func cancelBeforeStart() {
        guard phase == .pending else { return }
        finish()
    }
    func perform() async throws -> TrashRestore {
        guard phase == .pending else { throw CancellationError() }
        phase = .running
        defer { finish() }
        let restore = restore
        let result = try await Task.detached(priority: .userInitiated) { try restore() }.value
        let paths = result.items.filter { $0.status == "restored" }.map(\.original)
        if !paths.isEmpty { invalidate(paths) }
        return result
    }
    private func finish() {
        phase = .finished
        if let token { AppExitGuard.endRestore(token); self.token = nil }
    }
}
