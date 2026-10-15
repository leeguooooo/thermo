import AppKit

@MainActor
enum AppExitGuard {
    static func reply() -> NSApplication.TerminateReply {
        let model = AppModels.shared.softwareUpdates
        guard model.working else { return .terminateNow }
        model.exitRequested = true
        model.channel = "homebrew"
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
