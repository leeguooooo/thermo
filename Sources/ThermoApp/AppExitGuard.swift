import AppKit

@MainActor
enum AppExitGuard {
    private static var helperRemovals = Set<UUID>()
    static func beginHelperRemoval() -> UUID {
        let token = UUID(); helperRemovals.insert(token); return token
    }
    static func endHelperRemoval(_ token: UUID) { helperRemovals.remove(token) }

    static func reply(show: @MainActor (MainPage) -> Void = { MainWindow.show($0) }) -> NSApplication.TerminateReply {
        if !helperRemovals.isEmpty {
            show(.settings)
            return .terminateCancel
        }
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
