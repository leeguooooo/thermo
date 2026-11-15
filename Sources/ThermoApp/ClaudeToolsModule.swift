import ModuleKit
import SwiftUI

enum ClaudeToolsModule:BuiltinModule {
    static let manifest=BuiltinModuleManifests.claude
    static let legacyMenuEntries:[String:String]=[:]
    @MainActor static var enabled:Bool {ModuleCenter.shared.isOn(manifest.id)}
    static func owns(_ page:MainPage)->Bool {
        if case let .module(id,_)=page{return id==manifest.id}
        return false
    }
    static func canonicalArgument(_ argument:String)->String {
        if argument=="claude-cleanup" || argument.hasPrefix("claude-cleanup:") {return argument=="claude-cleanup:privacy" ? "claude:privacy":"claude:reset"}
        if argument=="claude" {return "claude:accounts"}
        if argument.hasPrefix("claude:") && !manifest.entries.contains(where:{$0.scene==argument}) {return "claude:accounts"}
        return argument
    }
    static func target(_ scene:String)->MainPage? {
        manifest.entries.first(where:{$0.scene==scene}).map{.module(manifest.id,$0.id)}
    }
    static func supports(_ entry:ModuleManifest.Entry)->Bool {entry.kind == .page && entry.scene.flatMap(target) != nil}
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop? {
        guard let drain=try models.nativeFeatures.prepareStop(manifest.id) else{return nil}
        return {await drain.finish()}
    }
}
