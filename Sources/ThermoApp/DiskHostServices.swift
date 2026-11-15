import NativeFeatureAPI
import ModuleKit
import DiskFeature
import Foundation

/// Application policy and cross-feature presentation stay in the assembly adapter.
@MainActor final class DiskHostServices:DiskServices {
    func requestScanNotifications(){SystemPresentation.requestNotificationPermission()}
    func revealInSpace(_ path:String)->Bool {Self.reveal(path)}
    static func reveal(_ path:String,models:AppModels = .shared,open:@MainActor (MainPage)->Void = {MainWindow.show($0)})->Bool {
        guard let page=spaceDestination(path,models:models) else{return false}
        open(page);return true
    }
    static func spaceDestination(_ path:String,models:AppModels = .shared)->MainPage? {
        guard let request=try? models.nativeFeatures.catalog.normalizePresentation(.init(route:.init(BuiltinModuleManifests.space.id,"browse"),options:["path":.text(path)])) else{return nil}
        if models.nativeFeatures.canPresent(request.route),!models.nativeFeatures.preparePresentation(request){return nil}
        return .native(request.route)
    }

}
