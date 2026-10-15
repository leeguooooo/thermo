import AppKit

@MainActor
enum AppExitGuard {
    static func reply() -> NSApplication.TerminateReply {
        let model = AppModels.shared.softwareUpdates
        let native = AppModels.shared.nativeUpdates
        guard model.working || native.installing else { return .terminateNow }
        if model.working { model.exitRequested = true; model.channel = "homebrew" }
        else { native.exitRequested = true; model.channel = "native" }
        MainWindow.show(.apps(.updates))
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
