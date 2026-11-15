import DownloadFeature
import ModuleKit

@MainActor final class DownloadHostPresentation: DownloadPresentation {
    var mainWindowActive:Bool {MainWindow.window?.isKeyWindow == true}
    func showDownloadPage() {MainWindow.show(.module(BuiltinModuleManifests.download.id,"home"))}
}
