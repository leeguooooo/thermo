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
    static let search=SearchFeature.registration(preview:{SearchPreviewServices.service(worker:SearchFeature.previewWorkerID)})
    static var registrations:[NativeFeatureDefinition] {registrations(environment:{.current})}
    static func registrations(environment:@escaping @MainActor @Sendable ()->ShellFeatureEnvironment)->[NativeFeatureDefinition] {
        let performance=PerformanceFeature.registration(telemetry:{environment().telemetry},administration:{environment().administration},
            fanFactory:{environment().fanFactory},defaults:{environment().defaults},actionsAllowed:{environment().actionsAllowed},showSettings:{environment().showSettings()})
        return [DiskFeature.registration(services:{DiskHostServices(environment:environment())}),search.definition,capture.definition,menuBar,performance,
            AgentDiagnosticsFeature.registration,SpaceFeature.registration(services:{SpaceHostServices(environment:environment())}),AppsFeature.registration,BrowserFeature.registration,
            DownloadFeature.registration(presentation:{DownloadHostPresentation(environment:environment())}),HistoryFeature.registration(services:{HistoryHostServices(environment:environment())}),
            ConnectionsFeature.registration(),ClaudeFeature.registration(),CheckupFeature.registration(reading:{environment().telemetry.latest.snapshot},navigate:{route in _=environment().open(.init(route:route))}),
            PluginsFeature.registration(navigate:{route in _=environment().open(.init(route:route))})]
    }
    static let catalog=try! NativeFeatureCatalog(definitions:registrations)
}
