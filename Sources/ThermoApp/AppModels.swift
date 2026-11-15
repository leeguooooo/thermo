import NativeFeatureAPI
import Foundation
import ModuleKit

/// What the app keeps once: the menu bar panel and the main window show the same models.
@MainActor
final class AppModels {
    static let shared = AppModels()
    lazy var services=AppSystemServices(defaults:defaults,samplingAllowed:{[defaults] in ModulePreferences.isEnabled(BuiltinModuleManifests.performance,in:defaults)})
    lazy var monitor=makeMonitor?() ?? Monitor(services:services,samplingAllowed:{[defaults] in ModulePreferences.isEnabled(BuiltinModuleManifests.performance,in:defaults)})
    private let defaults:UserDefaults
    private let makeMonitor:(() -> Monitor)?
    let nativeFeatures:NativeFeatureStore
    lazy var updates = Updates()
    init(defaults: UserDefaults = .standard, nativeDefinitions:[NativeFeatureDefinition]? = nil,
         makeMonitor:(() -> Monitor)? = nil) {
        self.defaults=defaults
        self.makeMonitor = makeMonitor
        let catalog=nativeDefinitions.map{try! NativeFeatureCatalog(definitions:$0)} ?? BuiltinNativeFeatures.catalog
        nativeFeatures=NativeFeatureStore(catalog:catalog,enabled:{id in
            guard let manifest=catalog.manifest(id) else{return false}
            return ModulePreferences.isEnabled(manifest,in:defaults)
        },navigation:.init(show:{MainWindow.showNative($0)}))
    }

}
