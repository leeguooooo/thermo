import NativeFeatureAPI
import AppKit
import CleanKit
import ModuleKit
import SwiftUI
import ThermoL10n

enum BrowserModule: BuiltinModule {
    static let manifest=BuiltinModuleManifests.browser
    static let legacyMenuEntries:[String:String]=[:]
    @MainActor static var enabled:Bool {ModuleCenter.shared.isOn(manifest.id)}
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
    @MainActor static func present(_ hog:MachinePulse.Hog,open:(MainPage)->Void) {
        var options:[String:NativeContextValue]=["appMemoryKB":.integer(Int64(hog.memoryKB))]
        if let gpu=hog.parts?.first(where:{$0.role=="GPU"})?.memoryKB {options["gpuMemoryKB"] = .integer(Int64(gpu))}
        let request=NativePresentationRequest(route:.init(manifest.id,"home",context:["app":.text(hog.name)]),options:options)
        guard NSApp.modalWindow == nil,MainWindow.window?.attachedSheet == nil,
              let canonical=try? BuiltinNativeFeatures.catalog.normalizePresentation(request) else{return}
        let store=AppModels.shared.nativeFeatures
        if store.canPresent(canonical.route),!store.preparePresentation(canonical) {return}
        open(.native(canonical.route))
    }
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop? {
        guard let drain=try models.nativeFeatures.prepareStop(manifest.id) else{return nil}
        return {await drain.finish()}
    }
}
