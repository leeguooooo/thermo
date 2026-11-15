import ModuleKit
import NativeFeatureAPI
import SwiftUI

enum DiskModule:BuiltinModule {
    static let manifest=BuiltinModuleManifests.disk
    static let legacyMenuEntries=["smartScan":"scan"]
    static let sidebarSections:Set<BuiltinSidebarSection>=[]
    static func owns(_ page:MainPage)->Bool {
        if case let .native(route)=page{return route.module==manifest.id}
        if case let .module(id,_)=page{return id==manifest.id}
        return false
    }
    static func canonicalArgument(_ argument:String)->String{argument=="disk:home" ? "disk":argument}
    static func target(_ scene:String)->MainPage?{manifest.entries.first{$0.kind == .page && $0.scene==scene}.map{.native(.init(manifest.id,$0.id))}}
    static func supports(_ entry:ModuleManifest.Entry)->Bool{entry.kind == .page ? entry.scene.flatMap(target) != nil:entry.kind == .settingsItem && entry.scene=="disk-protection"}
    @MainActor static func sidebar(section:BuiltinSidebarSection,page:Binding<MainPage>,models:AppModels,row:@escaping @MainActor (BuiltinSidebarItem)->AnyView)->AnyView{AnyView(EmptyView())}
    @MainActor static func page(_ entry:ModuleManifest.Entry,selection:Binding<MainPage>,models:AppModels)->AnyView{models.nativeFeatures.page(.init(manifest.id,entry.id)) ?? AnyView(EmptyView())}
    @MainActor static func settings(_ entry:ModuleManifest.Entry,models:AppModels)->AnyView{models.nativeFeatures.inlineSettings(.init(manifest.id,entry.id)) ?? AnyView(EmptyView())}
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop?{guard let drain=try models.nativeFeatures.prepareStop(manifest.id) else{return nil};return {await drain.finish()}}
    @MainActor static func appearance(_ page:MainPage)->(glow:Bool,tint:Color?){(false,nil)}
    @MainActor static func prepareReview(_ args:[String],page:inout MainPage,models:AppModels) {
        guard args.contains("--disk") else{return}
        let raw=args.firstIndex(of:"--page").flatMap{$0+1<args.count ? args[$0+1]:nil}
        page=raw.flatMap{MainPage(argument:"disk:"+$0)} ?? .native(.init(manifest.id,"scan"))
        if let route=page.nativeRoute {models.nativeFeatures.prepareReview(route,arguments:args)}
    }
    @MainActor static func snapshotReady(_ args:[String],models:AppModels,started:Date)->Bool {
        let raw=args.firstIndex(of:"--page").flatMap{$0+1<args.count ? args[$0+1]:nil}
        let page:MainPage?
        if args.contains("--disk"){page=raw.flatMap{MainPage(argument:"disk:"+$0)} ?? .native(.init(manifest.id,"scan"))}
        else{page=raw.flatMap(MainPage.init(argument:)) ?? .native(.init(manifest.id,"scan"))}
        guard let route=page?.nativeRoute,route.module==manifest.id else{return false}
        return models.nativeFeatures.snapshotReady(route,arguments:args,started:started)
    }
}
