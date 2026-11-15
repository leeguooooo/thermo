import HistoryFeature
import ClaudeFeature
import CheckupFeature
import PluginsFeature
import ConnectionsFeature
import NativeFeatureAPI

/// Assembly only. Feature targets keep their own models and views internal.
enum BuiltinNativeFeatures {
    @MainActor static var registrations:[NativeFeatureDefinition] {[HistoryFeature.registration(services:{HistoryHostServices()}),ConnectionsFeature.registration(),ClaudeFeature.registration(),CheckupFeature.registration(reading:{AppModels.shared.monitor.snapshot},navigate:{route in MainWindow.show(.module(route.module,route.entry))}),PluginsFeature.registration(navigate:{route in MainWindow.show(.module(route.module,route.entry))})]}
}
