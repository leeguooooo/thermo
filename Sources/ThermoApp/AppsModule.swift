import AppKit
import ModuleKit
import SwiftUI
import ThermoL10n

enum AppsModule: BuiltinModule {
    static let manifest = BuiltinModuleManifests.apps
    static let legacyMenuEntries: [String:String] = [:]
    static let sidebarSections: Set<BuiltinSidebarSection> = [.software]
    @MainActor static var enabled: Bool { ModuleCenter.shared.isOn(manifest.id) }
    static func owns(_ page: MainPage) -> Bool {
        if case .apps = page {return true}
        if case let .module(id,_) = page {return id == manifest.id}
        return false
    }
    static func canonicalArgument(_ argument: String) -> String { argument == "apps:feeds" ? "apps:updates" : argument }
    static func target(_ scene: String) -> MainPage? {
        if scene == "apps" {return .apps(.installed)}
        guard scene.hasPrefix("apps:"),let tab=AppsTab(rawValue:String(scene.dropFirst(5))) else{return nil}
        return .apps(tab)
    }
    static func supports(_ entry: ModuleManifest.Entry) -> Bool {entry.kind == .page && entry.scene.flatMap(target) != nil}
    @MainActor static func sidebar(section: BuiltinSidebarSection,page: Binding<MainPage>,models: AppModels,
                                  row: @escaping @MainActor (BuiltinSidebarItem)->AnyView) -> AnyView {
        guard section == .software,let entry=manifest.entries.first else{return AnyView(EmptyView())}
        let selected=owns(page.wrappedValue)
        let tab=page.wrappedValue.appsTab ?? BuiltinModules.page(page.wrappedValue)?.target?.appsTab ?? .installed
        return row(.init(entry:entry,target:.apps(tab),tint:.indigo,selected:selected))
    }
    @MainActor static func page(_ entry: ModuleManifest.Entry,selection: Binding<MainPage>,models: AppModels) -> AnyView {
        guard let tab=entry.scene.flatMap(target)?.appsTab else{return AnyView(ModuleOffView())}
        return AnyView(AppsPage(model:models.apps,startup:models.startup,updates:models.softwareUpdates,native:models.nativeUpdates,store:models.appStore,
            tab:Binding(get:{selection.wrappedValue.appsTab ?? tab},set:{selection.wrappedValue = .apps($0)})))
    }
    @MainActor static func settings(_ entry: ModuleManifest.Entry,models: AppModels) -> AnyView {AnyView(EmptyView())}
    @MainActor static func prepareStop(models: AppModels) throws -> BuiltinModules.FinishStop? {try models.prepareAppsStop()}
    @MainActor static func appearance(_ page: MainPage) -> (glow:Bool,tint:Color?) {(false,nil)}
    @MainActor static func prepareReview(_ arguments:[String],page:inout MainPage,models:AppModels) {
        guard enabled,owns(page),let index=arguments.firstIndex(of:"--page"),index+1<arguments.count else{return}
        if arguments[index+1] == "apps:feeds" {models.softwareUpdates.channel="native"}
    }
    @MainActor static func snapshotReady(_ arguments:[String],models:AppModels,started:Date) -> Bool {
        let raw=arguments.firstIndex(of:"--page").flatMap{$0+1<arguments.count ? arguments[$0+1]:nil} ?? "apps"
        let tab=MainPage(argument:raw).flatMap{BuiltinModules.page($0)?.target?.appsTab} ?? .installed
        switch tab {
        case .installed:return !models.apps.loading && !models.apps.apps.isEmpty
        case .leftovers:return models.apps.orphans != nil
        case .startup:return models.startup.report != nil && !models.startup.busy
        case .updates:return models.softwareUpdates.channel == "native"
            ? models.nativeUpdates.loaded && !models.nativeUpdates.loading
            : models.softwareUpdates.report != nil && !models.softwareUpdates.busy
        case .store:return models.appStore.loaded
        }
    }
}
