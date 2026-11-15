import SystemServicesAPI
import ThermoUI
import AppKit
import ModuleKit
import SwiftUI
import ThermoKit
import ThermoL10n

/// Native performance pages share existing demand-driven readers and the kernel's fan helper.
enum PerformanceModule: BuiltinModule {
    static let manifest = BuiltinModuleManifests.performance
    static let legacyMenuEntries: [String: String] = [:]
    @MainActor static var enabled: Bool { ModuleCenter.shared.isOn(manifest.id) }
    static func owns(_ page: MainPage) -> Bool {
        switch page {
        case .overview, .sensors, .fans, .memory, .compute: return true
        case let .module(id, _): return id == manifest.id
        default: return false
        }
    }
    static func canonicalArgument(_ argument: String) -> String { argument }
    static func target(_ scene: String) -> MainPage? {
        switch scene {
        case "overview": return .overview
        case "sensors": return .sensors
        case "fans": return .fans
        case "memory": return .memory
        case "cpu": return .compute(false)
        case "gpu": return .compute(true)
        default: return nil
        }
    }
    static func supports(_ entry: ModuleManifest.Entry) -> Bool { entry.kind == .page && entry.scene.flatMap(target) != nil }
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop? {
        guard let drain=try models.nativeFeatures.prepareStop(manifest.id) else{return nil};return{await drain.finish()}
    }
}
