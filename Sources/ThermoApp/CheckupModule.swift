import ModuleKit
import SwiftUI

enum CheckupModule:BuiltinModule {
    static let manifest=BuiltinModuleManifests.checkup
    static let legacyMenuEntries:[String:String]=[:]
    static let sidebarSections:Set<BuiltinSidebarSection>=[.overview]
    @MainActor static var enabled:Bool {ModuleCenter.shared.isOn(manifest.id)}
    static func owns(_ page:MainPage)->Bool {
        if case let .module(id,_)=page{return id==manifest.id}
        return false
    }
    static func canonicalArgument(_ argument:String)->String {argument}
    static func target(_ scene:String)->MainPage? {scene=="checkup" ? .module(manifest.id,"home"):nil}
    static func supports(_ entry:ModuleManifest.Entry)->Bool {entry.kind == .page && entry.scene=="checkup"}
    @MainActor static func sidebar(section:BuiltinSidebarSection,page:Binding<MainPage>,models:AppModels,row:@escaping @MainActor (BuiltinSidebarItem)->AnyView)->AnyView {
        guard section == .overview,let entry=manifest.entries.first else{return AnyView(EmptyView())}
        return row(.init(entry:entry,target:.module(manifest.id,entry.id),tint:.mint,selected:owns(page.wrappedValue)))
    }
    @MainActor static func page(_ entry:ModuleManifest.Entry,selection:Binding<MainPage>,models:AppModels)->AnyView {models.nativeFeatures.page(.init(manifest.id,entry.id)) ?? AnyView(EmptyView())}
    @MainActor static func settings(_ entry:ModuleManifest.Entry,models:AppModels)->AnyView {AnyView(EmptyView())}
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop? {
        guard let drain=try models.nativeFeatures.prepareStop(manifest.id) else{return nil}
        return {await drain.finish()}
    }
    @MainActor static func appearance(_ page:MainPage)->(glow:Bool,tint:Color?){(false,nil)}
    @MainActor static func prepareReview(_ args:[String],page:inout MainPage,models:AppModels) {
        guard owns(page),enabled,let index=args.firstIndex(of:"--fixture"),index+1<args.count else{return}
        models.nativeFeatures.prepareReview(.init(manifest.id,"home"),arguments:Array(args[index...]))
    }
    @MainActor static func snapshotReady(_ args:[String],models:AppModels,started:Date)->Bool {Date().timeIntervalSince(started)>2}
}
