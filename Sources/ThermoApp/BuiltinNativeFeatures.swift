import AgentDiagnosticsFeature
import SpaceFeature
import AppsFeature
import DownloadFeature
import HistoryFeature
import ClaudeFeature
import CheckupFeature
import PluginsFeature
import ConnectionsFeature
import BrowserFeature
import NativeFeatureAPI

/// Assembly only. Feature targets keep their own models and views internal.
enum BuiltinNativeFeatures {
    static var registrations:[NativeFeatureDefinition] {[AgentDiagnosticsFeature.registration,SpaceFeature.registration(services:{SpaceHostServices()}),AppsFeature.registration,BrowserFeature.registration,DownloadFeature.registration(presentation:{DownloadHostPresentation()}),HistoryFeature.registration(services:{HistoryHostServices()}),ConnectionsFeature.registration(),ClaudeFeature.registration(),CheckupFeature.registration(reading:{AppModels.shared.monitor.snapshot},navigate:{route in MainWindow.show(.module(route.module,route.entry))}),PluginsFeature.registration(navigate:{route in MainWindow.show(.module(route.module,route.entry))})]}
    static let catalog=try! NativeFeatureCatalog(definitions:registrations)
}
