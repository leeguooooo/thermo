import ModuleKit
import SwiftUI

enum AgentDiagnosticsModule:BuiltinModule {
    static let manifest=BuiltinModuleManifests.agents
    static let legacyMenuEntries:[String:String]=[:]
    // Dynamic rows are supplied by the same native definition's window UI descriptor.
    static let sidebarSections:Set<BuiltinSidebarSection>=[]
    @MainActor static var enabled:Bool{ModuleCenter.shared.isOn(manifest.id)}
    static func owns(_ page:MainPage)->Bool {
        if case let .native(route)=page{return route.module==manifest.id}
        if case let .module(id,_)=page{return id==manifest.id}
        return false
    }
    static func canonicalArgument(_ argument:String)->String{argument}
    static func target(_ scene:String)->MainPage?{manifest.entries.first{$0.kind == .page && $0.scene==scene}.map{.native(.init(manifest.id,$0.id))}}
    static func supports(_ entry:ModuleManifest.Entry)->Bool{entry.kind == .page && entry.scene.flatMap(target) != nil}
    @MainActor static func sidebar(section:BuiltinSidebarSection,page:Binding<MainPage>,models:AppModels,row:@escaping @MainActor (BuiltinSidebarItem)->AnyView)->AnyView{AnyView(EmptyView())}
    @MainActor static func page(_ entry:ModuleManifest.Entry,selection:Binding<MainPage>,models:AppModels)->AnyView{models.nativeFeatures.page(.init(manifest.id,entry.id)) ?? AnyView(EmptyView())}
    @MainActor static func settings(_ entry:ModuleManifest.Entry,models:AppModels)->AnyView{AnyView(EmptyView())}
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop?{guard let drain=try models.nativeFeatures.prepareStop(manifest.id) else{return nil};return {await drain.finish()}}
    @MainActor static func appearance(_ page:MainPage)->(glow:Bool,tint:Color?){(false,nil)}
    @MainActor static func prepareReview(_ args:[String],page:inout MainPage,models:AppModels) {
        guard let index=args.firstIndex(of:"--agents") else{return}
        let requested=index+1<args.count ? "agents:"+args[index+1]:"agents"
        guard let resolved=MainPage(argument:requested),case let .native(route)=resolved else{return}
        page=resolved;models.nativeFeatures.prepareReview(route,arguments:args)
    }
    @MainActor static func snapshotReady(_ args:[String],models:AppModels,started:Date)->Bool{models.nativeFeatures.status(manifest.id).snapshotReady}
}
