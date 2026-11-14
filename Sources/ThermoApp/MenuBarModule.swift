import AppKit
import ModuleKit
import SwiftUI
import ThermoL10n

/// Optional in-process menu bar management; native visibility is restored before retiring it.
enum MenuBarModule: BuiltinModule {
    static let manifest = BuiltinModuleManifests.menuBar
    static let legacyMenuEntries: [String: String] = [:]
    @MainActor static var enabled: Bool { ModuleCenter.shared.isOn(manifest.id) }
    @MainActor static func start() { MenuBarManager.shared.start() }
    static func owns(_ page: MainPage) -> Bool { false }
    static func canonicalArgument(_ argument: String) -> String { argument }
    static func target(_ scene: String) -> MainPage? { nil }
    static func supports(_ entry: ModuleManifest.Entry) -> Bool {
        switch (entry.kind, entry.scene) {
        case (.menuBarItem, "menu-bar-management"), (.settingsItem, "menu-bar-management"): return true
        default: return false
        }
    }
    @MainActor static func sidebar(page: Binding<MainPage>, models: AppModels,
                                  row: @escaping @MainActor (BuiltinSidebarItem) -> AnyView) -> AnyView { AnyView(EmptyView()) }
    @MainActor static func page(_ entry: ModuleManifest.Entry, selection: Binding<MainPage>, models: AppModels) -> AnyView { AnyView(ModuleOffView()) }
    @MainActor static func settings(_ entry: ModuleManifest.Entry, models: AppModels) -> AnyView {
        AnyView(HStack(spacing: Theme.Space.m) {
            Image(systemName: entry.symbol ?? manifest.symbol).frame(width: 22).foregroundStyle(Theme.textSecondary)
            Text(tr(entry.title)).font(Theme.body)
            Spacer()
            Button(tr("Open")) {
                MenuBarManagerPanel.shared.show()
            }.buttonStyle(PillButtonStyle()).controlSize(.small)
        }.padding(.horizontal, Theme.Space.m).padding(.vertical, 8))
    }
    @MainActor static func prepareStop(models: AppModels) throws -> BuiltinModules.FinishStop? {
        try MenuBarManager.shared.stopFeature()
        MenuBarManagerPanel.closeIfOpen()
        return nil
    }
    @MainActor static func appearance(_ page: MainPage) -> (glow: Bool, tint: Color?) { (false, nil) }
    @MainActor static func prepareReview(_ arguments: [String], page: inout MainPage, models: AppModels) {}
    @MainActor static func snapshotReady(_ arguments: [String], models: AppModels) -> Bool { true }
}

