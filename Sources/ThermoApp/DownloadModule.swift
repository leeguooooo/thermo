import ModuleKit
import SwiftUI

enum DownloadModule:BuiltinModule {
    static let manifest=BuiltinModuleManifests.download
    static let legacyMenuEntries:[String:String]=[:]
    @MainActor static var enabled:Bool {ModuleCenter.shared.isOn(manifest.id)}
    static func owns(_ page:MainPage)->Bool {
        if case let .module(id,_)=page{return id==manifest.id}
        return false
    }
    static func canonicalArgument(_ argument:String)->String {argument.hasPrefix("yunx:") ? "yunx":argument}
    static func target(_ scene:String)->MainPage? {scene=="yunx" ? .module(manifest.id,"home"):nil}
    static func supports(_ entry:ModuleManifest.Entry)->Bool {entry.kind == .page && entry.scene=="yunx"}
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop? {
        guard let drain=try models.nativeFeatures.prepareStop(manifest.id) else{return nil}
        return {await drain.finish()}
    }
}
