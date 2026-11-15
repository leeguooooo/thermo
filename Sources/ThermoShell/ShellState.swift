import NativeFeatureAPI
import Foundation
import ModuleKit

/// What the app keeps once: the menu bar panel and the main window show the same models.
@MainActor
final class ShellState {
    static let shared = ShellState()
    let services:AppSystemServices
    var preferences:UserDefaults{defaults}
    lazy var system=makeSystemPresentation?() ?? SystemPresentation(services:services)
    private let defaults:UserDefaults
    private let makeSystemPresentation:(() -> SystemPresentation)?
    let nativeFeatures:NativeFeatureStore
    let assembly:ShellFeatureAssembly
    lazy var updates = Updates()
    init(defaults: UserDefaults = .standard, services:AppSystemServices? = nil,nativeDefinitions:[NativeFeatureDefinition]? = nil,
         makeSystemPresentation:(() -> SystemPresentation)? = nil) {
        self.defaults=defaults
        self.makeSystemPresentation = makeSystemPresentation
        let interactive=NSClassFromString("XCTestCase") == nil
        let services=services ?? AppSystemServices(defaults:defaults,helperInteraction:interactive,samplingAllowed:{interactive && ModulePreferences.isEnabled(BuiltinModuleManifests.performance,in:defaults)})
        self.services=services
        let reference=ShellFeatureStoreReference()
        let environment=ShellFeatureEnvironment.bound(defaults:defaults,services:services,store:{reference.store})
        assembly=ShellFeatureInstallation.shared.makeAssembly(environment:{environment})
        let definitions=nativeDefinitions ?? assembly.definitions
        let catalog=try! NativeFeatureCatalog(definitions:definitions)
        nativeFeatures=NativeFeatureStore(catalog:catalog,enabled:{id in
            guard let manifest=catalog.manifest(id) else{return false}
            return ModulePreferences.isEnabled(manifest,in:defaults)
        },navigation:.init(show:{MainWindow.showNative($0)}))
        reference.store=nativeFeatures
    }

}
