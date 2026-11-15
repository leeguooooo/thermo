import ModuleKit
import NativeFeatureAPI
import SwiftUI

enum DiskModule:BuiltinModule {
    static let manifest=BuiltinModuleManifests.disk
    static let legacyMenuEntries=["smartScan":"scan"]
    static func owns(_ page:MainPage)->Bool {
        if case let .native(route)=page{return route.module==manifest.id}
        if case let .module(id,_)=page{return id==manifest.id}
        return false
    }
    static func canonicalArgument(_ argument:String)->String{argument=="disk:home" ? "disk":argument}
    static func target(_ scene:String)->MainPage?{manifest.entries.first{$0.kind == .page && $0.scene==scene}.map{.native(.init(manifest.id,$0.id))}}
    static func supports(_ entry:ModuleManifest.Entry)->Bool{entry.kind == .page ? entry.scene.flatMap(target) != nil:entry.kind == .settingsItem && entry.scene=="disk-protection"}
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop?{guard let drain=try models.nativeFeatures.prepareStop(manifest.id) else{return nil};return {await drain.finish()}}
}
