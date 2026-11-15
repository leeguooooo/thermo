import ModuleKit
import SwiftUI

enum DownloadModule:BuiltinModule {
    static let manifest=BuiltinModuleManifests.download
    static let legacyMenuEntries:[String:String]=[:]
    static let sidebarSections:Set<BuiltinSidebarSection>=[.software]
    @MainActor static var enabled:Bool {ModuleCenter.shared.isOn(manifest.id)}
    static func owns(_ page:MainPage)->Bool {
        if page == .yunx{return true}
        if case let .module(id,_)=page{return id==manifest.id}
        return false
    }
    static func canonicalArgument(_ argument:String)->String {argument}
    static func target(_ scene:String)->MainPage? {scene=="yunx" ? .yunx:nil}
    static func supports(_ entry:ModuleManifest.Entry)->Bool {entry.kind == .page && entry.scene=="yunx"}
    @MainActor static func sidebar(section:BuiltinSidebarSection,page:Binding<MainPage>,models:AppModels,row:@escaping @MainActor (BuiltinSidebarItem)->AnyView)->AnyView {
        guard section == .software,let entry=manifest.entries.first else{return AnyView(EmptyView())}
        return row(.init(entry:entry,target:.yunx,tint:.blue,selected:owns(page.wrappedValue)))
    }
    @MainActor static func page(_ entry:ModuleManifest.Entry,selection:Binding<MainPage>,models:AppModels)->AnyView {AnyView(YunXDownloadPage(model:models.download,setup:models.downloadSetup))}
    @MainActor static func start() {
        guard enabled else{return}
        YunXClipboardPrompt.shared.refresh()
        let setup=AppModels.shared.downloadSetup
        setup.work.runOnMain {[weak setup] in await setup?.offerOnLaunch()}
    }
    @MainActor static func settings(_ entry:ModuleManifest.Entry,models:AppModels)->AnyView {AnyView(EmptyView())}
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop? {try models.prepareDownloadStop()}
    @MainActor static func appearance(_ page:MainPage)->(glow:Bool,tint:Color?){(false,nil)}
    @MainActor static func prepareReview(_ arguments:[String],page:inout MainPage,models:AppModels) {}
    @MainActor static func snapshotReady(_ arguments:[String],models:AppModels,started:Date)->Bool {Date().timeIntervalSince(started)>2}
}
