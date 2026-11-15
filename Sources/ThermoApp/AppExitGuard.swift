import NativeFeatureAPI
import ModuleKit
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
    private static var manualRemovals: [UUID: @MainActor () -> Void] = [:]
    static func beginManualRemoval(onQuit: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID(); manualRemovals[token] = onQuit; return token
    }
    static func endManualRemoval(_ token: UUID) { manualRemovals[token] = nil }

    static func reply(nativeBlocker:@MainActor (String?)->NativeFeatureBlocker? = {AppModels.shared.nativeFeatures.quitBlocker($0)},show: @MainActor (MainPage) -> Void = { MainWindow.show($0) }) -> NSApplication.TerminateReply {
        if !restores.isEmpty {
            show(.module(BuiltinModuleManifests.history.id,"home"))
            return .terminateCancel
        }
        if !helperMaintenance.isEmpty {
            show(.settings)
            return .terminateCancel
        }
        if !manualRemovals.isEmpty {
            for notify in manualRemovals.values { notify() }
            show(.native(.init(BuiltinModuleManifests.space.id,"browse")))
            return .terminateCancel
        }
        if let blocker=nativeBlocker(BuiltinModuleManifests.download.id){show(.native(blocker.route));return .terminateCancel}
        if let blocker=nativeBlocker(BuiltinModuleManifests.plugins.id){show(.native(blocker.route));return .terminateCancel}
        if let blocker=nativeBlocker(BuiltinModuleManifests.claude.id){show(.native(blocker.route));return .terminateCancel}
        if let blocker=nativeBlocker(BuiltinModuleManifests.checkup.id){show(.native(blocker.route));return .terminateCancel}
        if let blocker=nativeBlocker(BuiltinModuleManifests.agents.id){show(.native(blocker.route));return .terminateCancel}
        if let blocker=nativeBlocker(BuiltinModuleManifests.connections.id){show(.native(blocker.route));return .terminateCancel}
        if let blocker=nativeBlocker(BuiltinModuleManifests.browser.id){show(.native(blocker.route));return .terminateCancel}
        if let blocker=nativeBlocker(BuiltinModuleManifests.apps.id){show(.native(blocker.route));return .terminateCancel}
        if let blocker=nativeBlocker(BuiltinModuleManifests.space.id){show(.native(blocker.route));return .terminateCancel}
        if BatteryCareModel.shared.requestQuit() {show(.settings);return .terminateCancel}
        if AWDLModel.shared.requestQuit() {show(.settings);return .terminateCancel}
        return .terminateNow
    }
}

@MainActor
final class MainOnlyDelegate: NSObject, NSApplicationDelegate {
    let featureLaunch = FeatureLaunchGate()
    var deferInstallationMonitor = false
    var selectionIsPresented: @MainActor () -> Bool = { FeatureSelectionWindow.isPresented }
    var reopenFeatureSelection: @MainActor () -> Bool = { FeatureSelectionWindow.reopenIfPresented() }
    var showMainWindow: @MainActor () -> Void = { MainWindow.show() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !deferInstallationMonitor { AppInstallationMonitor.shared.start() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if deferInstallationMonitor || featureLaunch.isSelecting || selectionIsPresented() { return }
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
        if deferInstallationMonitor || featureLaunch.isSelecting || selectionIsPresented() { return .terminateNow }
        return CaptureWorkspace.shared.terminationReply(AppExitGuard.reply(show: showExitBlocker))
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if reopenFeatureSelection() { return false }
        showMainWindow()
        return false
    }
}
