import ModuleKit
import NativeFeatureAPI

/// Host policy reads the checked catalogue; feature factories remain owned by their registrations.
enum NativeModules {
    static var all:[ModuleManifest] {BuiltinNativeFeatures.catalog.manifests}
    static func manifest(_ id:String)->ModuleManifest? {BuiltinNativeFeatures.catalog.manifest(id)}
    static func workerOwner(_ id:String)->ModuleManifest? {BuiltinNativeFeatures.catalog.workerOwner(id)}
    struct Page {
        let module:ModuleManifest
        let entry:ModuleManifest.Entry
        let target:MainPage?
    }
    static func page(_ page:MainPage)->Page? {
        guard let route=page.nativeRoute,let manifest=manifest(route.module),let entry=manifest.entries.first(where:{$0.id==route.entry && $0.kind == .page}) else{return nil}
        return .init(module:manifest,entry:entry,target:.native(route))
    }
    static func legacyMenuEntry(_ key:String)->Page? {
        guard let route=try? BuiltinNativeFeatures.catalog.resolveLegacyMenu(key) else{return nil}
        return page(.native(route))
    }
    static var problems:[String] {all.flatMap{$0.problems()}}
    @MainActor static func prepareReview(_ arguments:[String],page:MainPage,models:AppModels)throws->MainPage {
        var selected=page
        if let request=try models.nativeFeatures.catalog.resolveLegacyLaunch(arguments) {
            selected = .native(request.route)
            _=models.nativeFeatures.preparePresentation(request)
        }
        if let route=selected.nativeRoute {models.nativeFeatures.prepareReview(route,arguments:arguments)}
        return selected
    }
    @MainActor static func snapshotReady(_ page:MainPage,arguments:[String],models:AppModels,center:ModuleCenter,started:Date = .distantPast)->Bool? {
        guard let route=page.nativeRoute else{return nil}
        return models.nativeFeatures.snapshotReady(route,arguments:arguments,started:started)
    }
    typealias FinishStop = @MainActor () async->Void
    struct StopRefused:Error,CustomStringConvertible {let description:String}
    @MainActor static func prepareStop(_ id:String,models:AppModels = .shared)throws->FinishStop? {
        guard let drain=try models.nativeFeatures.prepareStop(id) else{return nil}
        return {await drain.finish()}
    }
    @MainActor static func start(_ id:String) {AppModels.shared.nativeFeatures.startBackground(id)}
}
