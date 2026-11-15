import ModuleKit
import SwiftUI

enum AgentDiagnosticsModule:BuiltinModule {
    static let manifest=BuiltinModuleManifests.agents
    static let legacyMenuEntries:[String:String]=[:]
    // Dynamic rows are supplied by the same native definition's window UI descriptor.
    @MainActor static var enabled:Bool{ModuleCenter.shared.isOn(manifest.id)}
    static func owns(_ page:MainPage)->Bool {
        if case let .native(route)=page{return route.module==manifest.id}
        if case let .module(id,_)=page{return id==manifest.id}
        return false
    }
    static func canonicalArgument(_ argument:String)->String{argument}
    static func target(_ scene:String)->MainPage?{manifest.entries.first{$0.kind == .page && $0.scene==scene}.map{.native(.init(manifest.id,$0.id))}}
    static func supports(_ entry:ModuleManifest.Entry)->Bool{entry.kind == .page && entry.scene.flatMap(target) != nil}
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop?{guard let drain=try models.nativeFeatures.prepareStop(manifest.id) else{return nil};return {await drain.finish()}}
}
