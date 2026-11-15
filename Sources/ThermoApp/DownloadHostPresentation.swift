import DownloadFeature
import ModuleKit

@MainActor final class DownloadHostPresentation: DownloadPresentation {
    private let environment:ShellFeatureEnvironment
    init(environment:ShellFeatureEnvironment = .current){self.environment=environment}
    var mainWindowActive:Bool {environment.mainWindowActive}
    func showDownloadPage() {_=environment.open(.init(route:.init(BuiltinModuleManifests.download.id,"home")))}
}
