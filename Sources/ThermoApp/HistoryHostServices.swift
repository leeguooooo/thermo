import Foundation
import CleanKit
import HistoryFeature
import NativeFeatureAPI
import ModuleKit
import ThermoL10n

/// Assembly adapter: history presentation never owns global quit protection or other features.
@MainActor final class HistoryHostServices: HistoryServices {
    private let environment:ShellFeatureEnvironment
    nonisolated private let reader: @Sendable () -> OperationJournal.ReadReport
    nonisolated private let reviewer: @Sendable (String) throws -> TrashRestore
    nonisolated private let restore: @Sendable (String, TrashRestore) throws -> TrashRestore
    private let invalidate: @MainActor ([String]) -> Void
    var journalURL: URL { OperationJournal.url() }

    init(environment:ShellFeatureEnvironment = .current,reader: @escaping @Sendable () -> OperationJournal.ReadReport = { OperationJournal.readReport(limit: 300) },
         reviewer: @escaping @Sendable (String) throws -> TrashRestore = { try TrashBatches.restore(id: $0, dryRun: true) },
         restore: @escaping @Sendable (String, TrashRestore) throws -> TrashRestore = { id, review in
             try TrashBatches.restore(id: id, reviewIdentity: review.reviewIdentity,
                 reviewedDestinations: Set(review.items.filter { $0.status == "restored" }.map(\.destination)))
         }, invalidate: (@MainActor ([String]) -> Void)? = nil) {
        self.environment=environment;self.reader=reader;self.reviewer=reviewer;self.restore=restore
        self.invalidate=invalidate ?? {environment.nativeFeatures?.invalidateAfterRestore($0)}
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
        return HostHistoryRestoration(protection:environment.protectRestore(),restore:{try restore(batch,review)},invalidate:invalidate)
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
        return .init(title:title,symbol:symbol,perform:{[environment] in Self.perform(destination,environment:environment)})
    }
    static func perform(_ destination:Destination,environment:ShellFeatureEnvironment = .current,
                        open:((NativeFeatureRoute)->Void)? = nil) {
        let request:NativePresentationRequest
        switch destination {
        case .nativeRecovery:request = .init(route:.init(BuiltinModuleManifests.apps.id,"updates"),options:["channel":.text("native"),"showRecovery":.boolean(true)])
        case .appUpdates:request = .init(route:.init(BuiltinModuleManifests.apps.id,"updates"))
        case .startup:request = .init(route:.init(BuiltinModuleManifests.apps.id,"startup"))
        case .claudeReset:request = .init(route:.init(BuiltinModuleManifests.claude.id,"reset"))
        case .privacy:request = .init(route:.init(BuiltinModuleManifests.claude.id,"privacy"))
        case .tabs:request = .init(route:.init(BuiltinModuleManifests.browser.id,"home",context:["app":.text("Google Chrome")]))
        case .searchSettings:environment.showSearchSettings();return
        case .trash:environment.openTrash();return
        case let .reveal(path):environment.reveal(path);return
        }
        guard let store=environment.nativeFeatures,let checked=try? store.catalog.normalizePresentation(request) else{return}
        if store.canPresent(checked.route),!store.preparePresentation(checked){return}
        if let open{open(checked.route)}else{_=environment.select(checked.route)}
    }
}

@MainActor private final class HostHistoryRestoration: HistoryRestoration {
    private enum Phase { case pending, running, finished }
    private var phase = Phase.pending
    private var protection:(any ShellQuitProtection)?
    private let restore: @Sendable () throws -> TrashRestore
    private let invalidate: @MainActor ([String]) -> Void
    init(protection:any ShellQuitProtection,restore:@escaping @Sendable () throws->TrashRestore,invalidate:@escaping @MainActor ([String])->Void) {
        self.restore = restore; self.invalidate = invalidate
        self.protection=protection
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
        protection?.finish();protection=nil
    }
}
