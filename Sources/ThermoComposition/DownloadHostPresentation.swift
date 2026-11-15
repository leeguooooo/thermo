import ThermoShell
import DownloadFeature
import ModuleKit

@MainActor final class DownloadHostPresentation: DownloadPresentation {
    private let environment:ShellFeatureEnvironment
    init(environment:ShellFeatureEnvironment? = nil){self.environment=environment ?? .current}
    var mainWindowActive:Bool {environment.mainWindowActive}
    func showDownloadPage() {_=environment.open(.init(route:.init(BuiltinModuleManifests.download.id,"home")))}
}
