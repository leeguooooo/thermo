import DownloadFeature
import ModuleKit

@MainActor final class DownloadHostPresentation: DownloadPresentation {
    var mainWindowActive:Bool {MainWindow.window?.isKeyWindow == true}
    func showDownloadPage() {MainWindow.show(.native(.init(BuiltinModuleManifests.download.id,"home")))}
}
