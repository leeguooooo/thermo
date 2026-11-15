import NativeFeatureAPI
import ModuleKit
import DiskFeature
import Foundation

/// Application policy and cross-feature presentation stay in the assembly adapter.
@MainActor final class DiskHostServices:DiskServices {
    private let environment:ShellFeatureEnvironment
    init(environment:ShellFeatureEnvironment = .current){self.environment=environment}
    func requestScanNotifications(){environment.requestScanNotifications()}
    func revealInSpace(_ path:String)->Bool {Self.reveal(path,environment:environment)}
    static func reveal(_ path:String,environment:ShellFeatureEnvironment = .current,open:((NativeFeatureRoute)->Void)? = nil)->Bool {
        guard let route=spaceDestination(path,environment:environment) else{return false}
        if let open{open(route);return true}
        return environment.select(route)
    }
    static func spaceDestination(_ path:String,environment:ShellFeatureEnvironment = .current)->NativeFeatureRoute? {
        guard let store=environment.nativeFeatures,
              let request=try? store.catalog.normalizePresentation(.init(route:.init(BuiltinModuleManifests.space.id,"browse"),options:["path":.text(path)])) else{return nil}
        if store.canPresent(request.route),!store.preparePresentation(request){return nil}
        return request.route
    }
}
