import PerformanceFeature
import NativeFeatureAPI
import Foundation
import ModuleKit

/// What the app keeps once: the menu bar panel and the main window show the same models.
@MainActor
final class AppModels {
    static let shared = AppModels()
    let services:AppSystemServices
    var preferences:UserDefaults{defaults}
    lazy var system=makeSystemPresentation?() ?? SystemPresentation(services:services)
    private let defaults:UserDefaults
    private let makeSystemPresentation:(() -> SystemPresentation)?
    let nativeFeatures:NativeFeatureStore
    lazy var updates = Updates()
    init(defaults: UserDefaults = .standard, services:AppSystemServices? = nil,nativeDefinitions:[NativeFeatureDefinition]? = nil,
         makeSystemPresentation:(() -> SystemPresentation)? = nil) {
        self.defaults=defaults
        self.makeSystemPresentation = makeSystemPresentation
        let interactive=NSClassFromString("XCTestCase") == nil
        let services=services ?? AppSystemServices(defaults:defaults,helperInteraction:interactive,samplingAllowed:{interactive && ModulePreferences.isEnabled(BuiltinModuleManifests.performance,in:defaults)})
        self.services=services
        let definitions=nativeDefinitions ?? BuiltinNativeFeatures.registrations(performance:PerformanceFeature.registration(
            telemetry:{services.telemetry},administration:{services.helper},fanFactory:{services.helper},defaults:{defaults},actionsAllowed:{!AppLaunchMode.suppressesAutomaticControl(arguments:CommandLine.arguments)},showSettings:{MainWindow.show(.settings)}),
            reading:{services.telemetry.latest.snapshot})
        let catalog=try! NativeFeatureCatalog(definitions:definitions)
        nativeFeatures=NativeFeatureStore(catalog:catalog,enabled:{id in
            guard let manifest=catalog.manifest(id) else{return false}
            return ModulePreferences.isEnabled(manifest,in:defaults)
        },navigation:.init(show:{MainWindow.showNative($0)}))
    }

}
