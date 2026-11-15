import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoL10n

enum SpaceModule:BuiltinModule {
    static let manifest=BuiltinModuleManifests.space
    static let legacyMenuEntries:[String:String]=[:]
    @MainActor static var enabled:Bool{ModuleCenter.shared.isOn(manifest.id)}
    static func owns(_ page:MainPage)->Bool {
        if case let .native(route)=page{return route.module==manifest.id}
        if case let .module(id,_)=page{return id==manifest.id}
        return false
    }
    static func canonicalArgument(_ argument:String)->String{argument}
    static func target(_ scene:String)->MainPage?{manifest.entries.first{$0.kind == .page && $0.scene==scene}.map{.native(.init(manifest.id,$0.id))}}
    static func supports(_ entry:ModuleManifest.Entry)->Bool{entry.kind == .page && entry.scene.flatMap(target) != nil}
    @MainActor static func sidebar(section:BuiltinSidebarSection,page:Binding<MainPage>,models:AppModels,row:@escaping @MainActor (BuiltinSidebarItem)->AnyView)->AnyView {
        guard section == .storage,let entry=manifest.entries.first else{return AnyView(EmptyView())}
        return row(.init(entry:entry,target:owns(page.wrappedValue) ? page.wrappedValue:.native(.init(manifest.id,entry.id)),tint:.cyan,selected:owns(page.wrappedValue)))
    }
    @MainActor static func page(_ entry:ModuleManifest.Entry,selection:Binding<MainPage>,models:AppModels)->AnyView{models.nativeFeatures.page(.init(manifest.id,entry.id)) ?? AnyView(EmptyView())}
    @MainActor static func reveal(_ path:String,models:AppModels = .shared)->MainPage? {
        guard let request=try? models.nativeFeatures.catalog.normalizePresentation(.init(route:.init(manifest.id,"browse"),options:["path":.text(path)])) else{return nil}
        if models.nativeFeatures.canPresent(request.route),!models.nativeFeatures.preparePresentation(request){return nil}
        return .native(request.route)
    }
    @MainActor static func settings(_ entry:ModuleManifest.Entry,models:AppModels)->AnyView{AnyView(EmptyView())}
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop?{guard let drain=try models.nativeFeatures.prepareStop(manifest.id) else{return nil};return {await drain.finish()}}
    @MainActor static func appearance(_ page:MainPage)->(glow:Bool,tint:Color?){(false,nil)}
    @MainActor static func prepareReview(_ arguments:[String],page:inout MainPage,models:AppModels){}
    @MainActor static func snapshotReady(_ arguments:[String],models:AppModels,started:Date)->Bool {
        let raw=arguments.firstIndex(of:"--page").flatMap{$0+1<arguments.count ? arguments[$0+1]:nil} ?? "space"
        guard let page=MainPage(argument:raw),owns(page),let entry=BuiltinModules.page(page)?.entry else{return false}
        return models.nativeFeatures.snapshotReady(.init(manifest.id,entry.id),arguments:arguments,started:started)
    }
}
