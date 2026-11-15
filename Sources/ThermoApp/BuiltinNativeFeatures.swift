import PerformanceFeature
import ThermoKit
import MenuBarFeature
import CaptureFeature
import SearchFeature
import DiskFeature
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
import AppKit

/// Assembly only. Feature targets keep their own models and views internal.
enum BuiltinNativeFeatures {
    static let menuBar=MenuBarFeature.registration(closeHostMenuPanel:{(NSApp.delegate as? AppDelegate)?.closeMenuPanel()})
    static let capture=CaptureFeature.registration()
    static let search=SearchFeature.registration(preview:{SearchPreviewServices.service})
    static var registrations:[NativeFeatureDefinition] {
        registrations(performance:PerformanceFeature.registration(telemetry:{AppModels.shared.services.telemetry},
            administration:{AppModels.shared.services.helper},fanFactory:{AppModels.shared.services.helper},
            defaults:{AppModels.shared.preferences},actionsAllowed:{!AppLaunchMode.suppressesAutomaticControl(arguments:CommandLine.arguments)},showSettings:{MainWindow.show(.settings)}),
            reading:{AppModels.shared.services.telemetry.latest.snapshot})
    }
    static func registrations(performance:NativeFeatureDefinition,reading:@escaping @MainActor @Sendable ()->Snapshot?)->[NativeFeatureDefinition] {
        [performance,search.definition,capture.definition,menuBar,DiskFeature.registration(services:{DiskHostServices()}),AgentDiagnosticsFeature.registration,SpaceFeature.registration(services:{SpaceHostServices()}),AppsFeature.registration,BrowserFeature.registration,DownloadFeature.registration(presentation:{DownloadHostPresentation()}),HistoryFeature.registration(services:{HistoryHostServices()}),ConnectionsFeature.registration(),ClaudeFeature.registration(),CheckupFeature.registration(reading:reading,navigate:{route in MainWindow.show(.module(route.module,route.entry))}),PluginsFeature.registration(navigate:{route in MainWindow.show(.module(route.module,route.entry))})]
    }
    static let catalog=try! NativeFeatureCatalog(definitions:registrations)
}
