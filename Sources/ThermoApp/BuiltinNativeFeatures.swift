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
    static var registrations:[NativeFeatureDefinition] {[BrowserFeature.registration,DownloadFeature.registration(presentation:{DownloadHostPresentation()}),HistoryFeature.registration(services:{HistoryHostServices()}),ConnectionsFeature.registration(),ClaudeFeature.registration(),CheckupFeature.registration(reading:{AppModels.shared.monitor.snapshot},navigate:{route in MainWindow.show(.native(route))}),PluginsFeature.registration(navigate:{route in MainWindow.show(.native(route))})]}
    static let catalog=try! NativeFeatureCatalog(definitions:registrations)
}
