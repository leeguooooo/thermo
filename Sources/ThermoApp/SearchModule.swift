import AppKit
import ModuleKit
import SwiftUI
import ThermoL10n

/// Native search/indexing with a private sandboxed renderer for untrusted document previews.
enum SearchModule: BuiltinModule {
    static let manifest = BuiltinModuleManifests.search
    static let previewWorker = "dev.thermo.search-preview"
    static let privateWorkers: Set<String> = [previewWorker]
    static let legacyMenuEntries: [String: String] = [:]
    @MainActor static var enabled: Bool { ModuleCenter.shared.isOn(manifest.id) }
    @MainActor static func start() { LocalSearchShortcut.shared.activate(); LocalSearchModel.shared.start() }
    static func owns(_ page: MainPage) -> Bool { false }
    static func canonicalArgument(_ argument: String) -> String { argument }
    static func target(_ scene: String) -> MainPage? { nil }
    static func supports(_ entry: ModuleManifest.Entry) -> Bool {
        switch (entry.kind, entry.scene) {
        case (.menuBarItem, "search-panel"), (.settingsItem, "search-settings"): return true
        default: return false
        }
    }
    @MainActor static func sidebar(section: BuiltinSidebarSection, page: Binding<MainPage>, models: AppModels,
                                  row: @escaping @MainActor (BuiltinSidebarItem) -> AnyView) -> AnyView { AnyView(EmptyView()) }
    @MainActor static func page(_ entry: ModuleManifest.Entry, selection: Binding<MainPage>, models: AppModels) -> AnyView { AnyView(ModuleOffView()) }
    @MainActor static func settings(_ entry: ModuleManifest.Entry, models: AppModels) -> AnyView {
        AnyView(HStack(spacing: Theme.Space.m) {
            Image(systemName: entry.symbol ?? manifest.symbol).frame(width: 22).foregroundStyle(Theme.textSecondary)
            Text(tr(entry.title)).font(Theme.body)
            Spacer()
            Button(tr("Open")) {
                LocalSearchPanel.shared.show(settings: true)
            }.buttonStyle(PillButtonStyle()).controlSize(.small)
        }.padding(.horizontal, Theme.Space.m).padding(.vertical, 8))
    }
    @MainActor static func prepareStop(models: AppModels) throws -> BuiltinModules.FinishStop? {
        guard !LocalSearchModel.shared.presentingDialog else {
            throw BuiltinModules.StopRefused(description: tr("Finish the current search dialog before switching this feature off."))
        }
        do { try LocalSearchShortcut.shared.deactivate() }
        catch { throw BuiltinModules.StopRefused(description: error.localizedDescription) }
        LocalSearchModel.shared.stop()
        SearchPreviewController.shared.stop()
        LocalSearchPanel.closeIfOpen()
        return {
            await LocalSearchModel.shared.finishStopping()
            await SearchPreviewController.shared.finishStopping()
            ModuleCenter.shared.manager.setEnabled(previewWorker, false)
        }
    }
    @MainActor static func appearance(_ page: MainPage) -> (glow: Bool, tint: Color?) { (false, nil) }
    @MainActor static func prepareReview(_ arguments: [String], page: inout MainPage, models: AppModels) {}
    @MainActor static func snapshotReady(_ arguments: [String], models: AppModels, started: Date) -> Bool { true }
}

