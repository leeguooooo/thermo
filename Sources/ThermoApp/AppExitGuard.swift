import AppKit

@MainActor
enum AppExitGuard {
    private static var helperMaintenance = Set<UUID>()
    static func beginHelperMaintenance() -> UUID {
        let token = UUID(); helperMaintenance.insert(token); return token
    }
    static func endHelperMaintenance(_ token: UUID) { helperMaintenance.remove(token) }
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
        if !helperMaintenance.isEmpty {
            show(.settings)
            return .terminateCancel
        }
        if !manualRemovals.isEmpty {
            for notify in manualRemovals.values { notify() }
            show(.space(.browse))
            return .terminateCancel
        }
        if let page=AppModels.shared.downloadExitBlocker(){show(page);return .terminateCancel}
        if let page=AppModels.shared.pluginsExitBlocker(){show(page);return .terminateCancel}
        if let page=AppModels.shared.claudeExitBlocker(){show(page);return .terminateCancel}
        if let page=AppModels.shared.checkupExitBlocker(){show(page);return .terminateCancel}
        if let page=AppModels.shared.agentsExitBlocker(){show(page);return .terminateCancel}
        if let blocker=AppModels.shared.nativeFeatures.quitBlocker(){show(.module(blocker.route.module,blocker.route.entry));return .terminateCancel}
        if let page=AppModels.shared.browserExitBlocker() {show(page);return .terminateCancel}
        if let page=AppModels.shared.softwareExitBlocker() {
            show(page);return .terminateCancel
        }
        if BatteryCareModel.shared.requestQuit() {show(.settings);return .terminateCancel}
        if AWDLModel.shared.requestQuit() {show(.settings);return .terminateCancel}
        return .terminateNow
    }
}

@MainActor
final class MainOnlyDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { AppInstallationMonitor.shared.start() }
    func applicationWillTerminate(_ notification: Notification) {
        MenuBarManager.shared.shutdown()
    }
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
        CaptureWorkspace.shared.terminationReply(AppExitGuard.reply(show: showExitBlocker))
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return false
    }
}
