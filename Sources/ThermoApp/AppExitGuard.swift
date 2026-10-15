import AppKit

@MainActor
enum AppExitGuard {
    static func reply(show: @MainActor (MainPage) -> Void = { MainWindow.show($0) }) -> NSApplication.TerminateReply {
        if AppModels.shared.apps.working {
            AppModels.shared.apps.exitRequested = true
            show(.apps(.installed))
            return .terminateCancel
        }
        let model = AppModels.shared.softwareUpdates
        let native = AppModels.shared.nativeUpdates
        if AppModels.shared.startup.working {
            AppModels.shared.startup.exitRequested = true
            show(.apps(.startup))
            return .terminateCancel
        }
        guard model.working || native.installing else { return .terminateNow }
        if model.working { model.exitRequested = true; model.channel = "homebrew" }
        else { native.exitRequested = true; model.channel = "native" }
        show(.apps(.updates))
        return .terminateCancel
    }
}

@MainActor
final class MainOnlyDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { AppExitGuard.reply() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return false
    }
}
