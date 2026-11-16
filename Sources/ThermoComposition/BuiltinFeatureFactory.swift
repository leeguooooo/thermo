import ThermoShell
import SystemServicesAPI
import PerformanceFeature
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

/// Assembly only. Feature targets keep their own models and views internal.
struct BuiltinFeatureFactory:ShellFeatureFactory {
    func makeAssembly(environment:@escaping @MainActor @Sendable ()->ShellFeatureEnvironment)->ShellFeatureAssembly {
        let menuBar=MenuBarFeature.registration(closeHostMenuPanel:{environment().closeMenuPanel()})
        let capture=CaptureFeature.registration()
        let search=SearchFeature.registration(discovery:{environment().discovery},preview:{environment().previewService(worker:SearchFeature.previewWorkerID)})
        let performance=PerformanceFeature.registration(telemetry:{environment().telemetry},administration:{environment().administration},
            fanFactory:{environment().fanFactory},defaults:{environment().defaults},actionsAllowed:{environment().actionsAllowed},showSettings:{environment().showSettings()})
        let definitions=[DiskFeature.registration(services:{DiskHostServices(environment:environment())}),search.definition,capture.definition,menuBar,performance,
            AgentDiagnosticsFeature.registration,SpaceFeature.registration(services:{SpaceHostServices(environment:environment())}),AppsFeature.registration,BrowserFeature.registration,
            DownloadFeature.registration(presentation:{DownloadHostPresentation(environment:environment())}),HistoryFeature.registration(services:{HistoryHostServices(environment:environment())}),
            ConnectionsFeature.registration(),ClaudeFeature.registration(),CheckupFeature.registration(discovery:{environment().discovery},reading:{environment().telemetry.latest.snapshot},navigate:{route in _=environment().open(.init(route:route))}),
            PluginsFeature.registration(navigate:{route in _=environment().open(.init(route:route))})]
        return .init(definitions:definitions,makeSearchAccess:search.makeAccess,makeCaptureControl:capture.makeControl)
    }
}
