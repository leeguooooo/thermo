import ModuleKit
import SwiftUI

enum CheckupModule:BuiltinModule {
    static let manifest=BuiltinModuleManifests.checkup
    static let legacyMenuEntries:[String:String]=[:]
    static let sidebarSections:Set<BuiltinSidebarSection>=[.overview]
    @MainActor static var enabled:Bool {ModuleCenter.shared.isOn(manifest.id)}
    static func owns(_ page:MainPage)->Bool {
        if page == .checkup{return true}
        if case let .module(id,_)=page{return id==manifest.id}
        return false
    }
    static func canonicalArgument(_ argument:String)->String {argument}
    static func target(_ scene:String)->MainPage? {scene=="checkup" ? .checkup:nil}
    static func supports(_ entry:ModuleManifest.Entry)->Bool {entry.kind == .page && entry.scene=="checkup"}
    @MainActor static func sidebar(section:BuiltinSidebarSection,page:Binding<MainPage>,models:AppModels,row:@escaping @MainActor (BuiltinSidebarItem)->AnyView)->AnyView {
        guard section == .overview,let entry=manifest.entries.first else{return AnyView(EmptyView())}
        return row(.init(entry:entry,target:.checkup,tint:.mint,selected:owns(page.wrappedValue)))
    }
    @MainActor static func page(_ entry:ModuleManifest.Entry,selection:Binding<MainPage>,models:AppModels)->AnyView {AnyView(CheckupPage(monitor:models.monitor,open:{selection.wrappedValue=$0},model:models.checkup))}
    @MainActor static func settings(_ entry:ModuleManifest.Entry,models:AppModels)->AnyView {AnyView(EmptyView())}
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop? {try models.prepareCheckupStop()}
    @MainActor static func appearance(_ page:MainPage)->(glow:Bool,tint:Color?){(false,nil)}
    @MainActor static func prepareReview(_ args:[String],page:inout MainPage,models:AppModels) {
        guard owns(page),enabled,let index=args.firstIndex(of:"--fixture"),index+1<args.count else{return}
        models.checkup.loadFixture(answer:args[index+1])
    }
    @MainActor static func snapshotReady(_ args:[String],models:AppModels,started:Date)->Bool {Date().timeIntervalSince(started)>2}
}
