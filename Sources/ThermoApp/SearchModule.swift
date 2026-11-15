import ModuleKit
import SearchFeature
import SwiftUI

enum SearchModule:BuiltinModule {
    static let manifest=BuiltinModuleManifests.search
    static let previewWorker=SearchFeature.previewWorkerID
    static let legacyMenuEntries:[String:String]=[:]
    @MainActor static var enabled:Bool{ModuleCenter.shared.isOn(manifest.id)}
    @MainActor static var access:any SearchApplicationAccess{BuiltinNativeFeatures.search.makeAccess(AppModels.shared.nativeFeatures)}
    @MainActor @discardableResult static func show(settings:Bool = false)->Bool{access.show(settings:settings)}
    static func owns(_ page:MainPage)->Bool{false}
    static func canonicalArgument(_ argument:String)->String{argument}
    static func target(_ scene:String)->MainPage?{nil}
    static func supports(_ entry:ModuleManifest.Entry)->Bool {
        switch(entry.kind,entry.scene){case(.menuBarItem,"search-panel"),(.settingsItem,"search-settings"):return true;default:return false}
    }
    @MainActor static func prepareStop(models:AppModels)throws->BuiltinModules.FinishStop? {
        guard let drain=try models.nativeFeatures.prepareStop(manifest.id) else{return nil}
        return {await drain.finish()}
    }
}
