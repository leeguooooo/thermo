import AppKit
import CleanKit
import ModuleKit
import SwiftUI
import ThermoL10n

enum BrowserModule: BuiltinModule {
    static let manifest=BuiltinModuleManifests.browser
    static let legacyMenuEntries:[String:String]=[:]
    static let sidebarSections:Set<BuiltinSidebarSection>=[.resources]
    @MainActor static var enabled:Bool {ModuleCenter.shared.isOn(manifest.id)}
    @MainActor static func start() {if enabled {TabAutomation.shared.start()}}
    static func owns(_ page:MainPage)->Bool {
        if case .browser=page{return true}
        if case let .module(id,_)=page{return id==manifest.id}
        return false
    }
    static func entry(for page:MainPage)->ModuleManifest.Entry? {
        if case .browser=page{return manifest.entries.first}
        return nil
    }
    static func canonicalArgument(_ argument:String)->String {argument}
    static func target(_ scene:String)->MainPage? {scene=="pages" ? .browser("Google Chrome"):nil}
    static func supports(_ entry:ModuleManifest.Entry)->Bool {
        entry.kind == .page && entry.scene=="pages" || entry.kind == .menuBarItem && entry.scene=="archive-tabs"
    }
    @MainActor static func sidebar(section:BuiltinSidebarSection,page:Binding<MainPage>,models:AppModels,
                                  row:@escaping @MainActor (BuiltinSidebarItem)->AnyView)->AnyView {
        guard section == .resources,let entry=manifest.entries.first else{return AnyView(EmptyView())}
        let app:String
        if case let .browser(selected)=page.wrappedValue {app=selected}else{app="Google Chrome"}
        return row(.init(entry:entry,target:.browser(app),tint:.teal,selected:owns(page.wrappedValue)))
    }
    @MainActor static func page(_ entry:ModuleManifest.Entry,selection:Binding<MainPage>,models:AppModels)->AnyView {
        let app:String
        if case let .browser(selected)=selection.wrappedValue {app=selected}else{app="Google Chrome"}
        return AnyView(ChromePagesView(model:models.browser(app),embedded:true).id(app))
    }
    @MainActor static func settings(_ entry:ModuleManifest.Entry,models:AppModels)->AnyView {AnyView(EmptyView())}
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop? {try models.prepareBrowserStop()}
    @MainActor static func appearance(_ page:MainPage)->(glow:Bool,tint:Color?){(false,nil)}
    @MainActor static func prepareReview(_ args:[String],page:inout MainPage,models:AppModels) {
        guard args.contains("--chrome-pages") else{return}
        let app=args.firstIndex(of:"--app").flatMap{$0+1<args.count ? args[$0+1]:nil} ?? "Google Chrome"
        page = .browser(app)
        guard enabled else{return}
        let hog=MachinePulse.sample().hogs.first{$0.name==app}
        let model=models.browser(app,memoryKB:hog?.memoryKB,gpuKB:hog?.parts?.first{$0.role=="GPU"}?.memoryKB)
        if let index=args.firstIndex(of:"--fixture"),index+2<args.count {model.loadFixture(before:args[index+1],after:args[index+2])}
        page = .browser(app)
    }
    @MainActor static func snapshotReady(_ args:[String],models:AppModels,started:Date)->Bool {
        let raw=args.firstIndex(of:"--page").flatMap{$0+1<args.count ? args[$0+1]:nil}
        let requested=raw.flatMap(MainPage.init(argument:))
        let app:String
        if case let .browser(name)?=requested {app=name}
        else {app=args.firstIndex(of:"--app").flatMap{$0+1<args.count ? args[$0+1]:nil} ?? "Google Chrome"}
        let diagnostics=args.firstIndex(of:"--tabs-task").flatMap{$0+1<args.count ? args[$0+1]:nil} == "diagnostics"
        if diagnostics {let model=models.browser(app);return model.diagnosis != nil && !model.running}
        return TabWorkspaceModel.loadedApps.contains(app)
    }
}
