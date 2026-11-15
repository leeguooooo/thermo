import NativeFeatureAPI
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
    @MainActor static func start() {AppModels.shared.nativeFeatures.start(manifest.id)}
    static func owns(_ page:MainPage)->Bool {
        if case let .native(route)=page{return route.module==manifest.id}
        if case let .module(id,_)=page{return id==manifest.id}
        return false
    }
    static func entry(for page:MainPage)->ModuleManifest.Entry? {
        if case let .native(route)=page{return manifest.entries.first{$0.id==route.entry}}
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
        let target=owns(page.wrappedValue) ? page.wrappedValue:.browser("Google Chrome")
        return row(.init(entry:entry,target:target,tint:.teal,selected:owns(page.wrappedValue)))
    }
    @MainActor static func page(_ entry:ModuleManifest.Entry,selection:Binding<MainPage>,models:AppModels)->AnyView {
        let route:NativeFeatureRoute
        if case let .native(value)=selection.wrappedValue {route=value}else{route = .init(manifest.id,entry.id)}
        return models.nativeFeatures.page(route) ?? AnyView(EmptyView())
    }
    @MainActor static func present(_ hog:MachinePulse.Hog,open:(MainPage)->Void) {
        var options:[String:NativeContextValue]=["appMemoryKB":.integer(Int64(hog.memoryKB))]
        if let gpu=hog.parts?.first(where:{$0.role=="GPU"})?.memoryKB {options["gpuMemoryKB"] = .integer(Int64(gpu))}
        let request=NativePresentationRequest(route:.init(manifest.id,"home",context:["app":.text(hog.name)]),options:options)
        guard NSApp.modalWindow == nil,MainWindow.window?.attachedSheet == nil,
              let canonical=try? BuiltinNativeFeatures.catalog.normalizePresentation(request),
              AppModels.shared.nativeFeatures.preparePresentation(canonical) else{return}
        open(.native(canonical.route))
    }
    @MainActor static func settings(_ entry:ModuleManifest.Entry,models:AppModels)->AnyView {AnyView(EmptyView())}
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop? {
        guard let drain=try models.nativeFeatures.prepareStop(manifest.id) else{return nil}
        return {await drain.finish()}
    }
    @MainActor static func appearance(_ page:MainPage)->(glow:Bool,tint:Color?){(false,nil)}
    @MainActor static func prepareReview(_ args:[String],page:inout MainPage,models:AppModels) {
        guard args.contains("--chrome-pages") else{return}
        let app=args.firstIndex(of:"--app").flatMap{$0+1<args.count ? args[$0+1]:nil} ?? "Google Chrome"
        guard let route=try? BuiltinNativeFeatures.catalog.normalize(.init(manifest.id,"home",context:["app":.text(app)])) else{return}
        page = .native(route)
        models.nativeFeatures.prepareReview(route,arguments:args)
    }
    @MainActor static func snapshotReady(_ args:[String],models:AppModels,started:Date)->Bool {
        let app=args.firstIndex(of:"--app").flatMap{$0+1<args.count ? args[$0+1]:nil} ?? "Google Chrome"
        return models.nativeFeatures.snapshotReady(.init(manifest.id,"home",context:["app":.text(app)]),arguments:args,started:started)
    }
}
