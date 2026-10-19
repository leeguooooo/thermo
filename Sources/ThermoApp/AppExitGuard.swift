import AppKit

@MainActor
enum AppExitGuard {
    private static var helperRemovals = Set<UUID>()
    static func beginHelperRemoval() -> UUID {
        let token = UUID(); helperRemovals.insert(token); return token
    }
    static func endHelperRemoval(_ token: UUID) { helperRemovals.remove(token) }
    private static var restores = Set<UUID>()
    static func beginRestore() -> UUID { let token = UUID(); restores.insert(token); return token }
    static func endRestore(_ token: UUID) { restores.remove(token) }
    private static var manualRemovals: [UUID: () -> Void] = [:]
    static func beginManualRemoval(onQuit: @escaping () -> Void) -> UUID {
        let token = UUID(); manualRemovals[token] = onQuit; return token
    }
    static func endManualRemoval(_ token: UUID) { manualRemovals[token] = nil }

    static func reply(show: @MainActor (MainPage) -> Void = { MainWindow.show($0) }) -> NSApplication.TerminateReply {
        if !restores.isEmpty {
            show(.history)
            return .terminateCancel
        }
        if !helperRemovals.isEmpty {
            show(.settings)
            return .terminateCancel
        }
        if !manualRemovals.isEmpty {
            for notify in manualRemovals.values { notify() }
            show(.space(.browse))
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
        guard model.working || native.installing else {
            if BatteryCareModel.shared.requestQuit() { show(.settings); return .terminateCancel }
            if AWDLModel.shared.requestQuit() { show(.settings);return .terminateCancel }
            return .terminateNow
        }
        if model.working { model.exitRequested = true; model.channel = "homebrew" }
        else { native.exitRequested = true; model.channel = "native" }
        show(.apps(.updates))
        return .terminateCancel
    }
}

@MainActor
final class MainOnlyDelegate: NSObject, NSApplicationDelegate {
    var showExitBlocker: @MainActor (MainPage) -> Void = { MainWindow.show($0) }
    /// Shared by the standalone entry point and an offscreen AppKit acceptance test.
    /// Termination is deferred until other close observers have retired page content.
    static func observeMainWindowClosing(
        window: @escaping @MainActor () -> NSWindow? = { MainWindow.window },
        requestTermination: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                guard let closed = notification.object as? NSWindow, closed === window() else { return }
                DispatchQueue.main.async { requestTermination() }
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppExitGuard.reply(show: showExitBlocker)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return false
    }
}
