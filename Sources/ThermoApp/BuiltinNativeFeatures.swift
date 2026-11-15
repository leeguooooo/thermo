import PluginsFeature
import ConnectionsFeature
import NativeFeatureAPI

/// Assembly only. Feature targets keep their own models and views internal.
enum BuiltinNativeFeatures {
    @MainActor static var registrations:[NativeFeatureDefinition] {[ConnectionsFeature.registration(),PluginsFeature.registration(navigate:{route in MainWindow.show(.module(route.module,route.entry))})]}
}
