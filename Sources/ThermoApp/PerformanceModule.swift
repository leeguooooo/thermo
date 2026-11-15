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
    static let sidebarSections: Set<BuiltinSidebarSection> = []
    @MainActor static var enabled: Bool { ModuleCenter.shared.isOn(manifest.id) }
    @MainActor private static var legacyOperations=Set<UUID>()
    @MainActor static func beginOperation()->UUID? {guard enabled else{return nil};let id=UUID();legacyOperations.insert(id);return id}
    @MainActor static func endOperation(_ id:UUID){legacyOperations.remove(id)}
    @MainActor static func start(){AppModels.shared.nativeFeatures.start(manifest.id)}
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
    static func section(_ entry: ModuleManifest.Entry) -> BuiltinSidebarSection? {
        switch entry.id {
        case "overview": return .overview
        case "sensors", "fans": return .machine
        case "cpu", "gpu", "memory": return .resources
        default: return nil
        }
    }
    @MainActor static func sidebar(section:BuiltinSidebarSection,page:Binding<MainPage>,models:AppModels,row:@escaping @MainActor(BuiltinSidebarItem)->AnyView)->AnyView {AnyView(EmptyView())}
    @MainActor static func page(_ entry:ModuleManifest.Entry,selection:Binding<MainPage>,models:AppModels)->AnyView {
        models.nativeFeatures.page(.init(manifest.id,entry.id)) ?? AnyView(ModuleOffView())
    }
    @MainActor static func settings(_ entry:ModuleManifest.Entry,models:AppModels)->AnyView {AnyView(EmptyView())}
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop? {
        guard let drain=try models.nativeFeatures.prepareStop(manifest.id) else{return nil};return{await drain.finish()}
    }
    @MainActor static func appearance(_ page:MainPage)->(glow:Bool,tint:Color?){(false,nil)}
    @MainActor static func prepareReview(_ arguments:[String],page:inout MainPage,models:AppModels) {
        guard let entry=BuiltinModules.page(page)?.entry else{return}
        models.nativeFeatures.prepareReview(.init(manifest.id,entry.id),arguments:arguments)
    }
    @MainActor static func snapshotReady(_ arguments:[String],models:AppModels,started:Date)->Bool {
        let raw=arguments.firstIndex(of:"--page").flatMap{$0+1<arguments.count ? arguments[$0+1]:nil} ?? "overview"
        guard let page=MainPage(argument:raw),let entry=BuiltinModules.page(page)?.entry else{return false}
        return models.nativeFeatures.snapshotReady(.init(manifest.id,entry.id),arguments:arguments,started:started)
    }
}
