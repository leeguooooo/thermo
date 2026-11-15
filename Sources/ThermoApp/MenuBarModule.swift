import ThermoUI
import AppKit
import ModuleKit
import SwiftUI
import ThermoL10n

/// Optional in-process menu bar management; native visibility is restored before retiring it.
enum MenuBarModule: BuiltinModule {
    static let manifest = BuiltinModuleManifests.menuBar
    static let legacyMenuEntries: [String: String] = [:]
    @MainActor static var enabled: Bool { ModuleCenter.shared.isOn(manifest.id) }
    static func owns(_ page: MainPage) -> Bool { false }
    static func canonicalArgument(_ argument: String) -> String { argument }
    static func target(_ scene: String) -> MainPage? { nil }
    static func supports(_ entry: ModuleManifest.Entry) -> Bool {
        switch (entry.kind, entry.scene) {
        case (.menuBarItem, "menu-bar-management"), (.settingsItem, "menu-bar-management"): return true
        default: return false
        }
    }
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop? {
        guard let drain=try models.nativeFeatures.prepareStop(manifest.id) else{return nil}
        return {await drain.finish()}
    }
}
