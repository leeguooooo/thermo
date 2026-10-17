// Visible production window; isolated home, no single-instance/control transport,
// no startup shortcut or charging restoration, automatic helper interaction off.
@testable import ThermoApp
import AppKit
import Foundation
import ThermoL10n
import CleanKit

@_silgen_name("$s9ThermoApp20installStandardMenusyyF")
@MainActor func fixtureStandardMenus() {}

@MainActor final class MainReviewDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { AppExitGuard.reply() }
    func applicationWillTerminate(_ notification: Notification) { print("QA_EXIT"); fflush(stdout) }
}
@main struct MainWindowUIAcceptance {
    @MainActor static func main() throws {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "ThermoFixtureRoot") as? String else { exit(2) }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("thermo-window-ui-"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".thermo-window-ui-fixture").path),
              URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == root.appendingPathComponent("home"),
              FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath() == root.appendingPathComponent("home") else { exit(3) }
        _ = freopen(root.appendingPathComponent("trace.log").path, "a", stdout)
        print("QA_ISOLATED_HOME true"); fflush(stdout)
        L10n.apply(preference: "zh-Hans"); Settings.register()
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = MainReviewDelegate(); app.delegate = delegate
        let menu = NSMenu(), item = NSMenuItem(), submenu = NSMenu()
        submenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
        AppModels.shared.monitor = Monitor(helperInteraction: false, arguments: ["Thermo", "--main", "--ui-review"])
        if Bundle.main.object(forInfoDictionaryKey: "ThermoScanFixture") as? String == "denied-empty" {
            var report = ScanReport(items: [], denied: [root.appendingPathComponent("home/unreadable-fixture").path], started: Date(), duration: 0)
            report.categories = [.browsers]; report.language = "zh-Hans"
            AppModels.shared.disk = DiskModel(report: report, requestNotifications: {})
            MainWindow.show(.disk(.category(.browsers)))
        } else {
            AppModels.shared.disk = DiskModel(requestNotifications: {})
            MainWindow.show(.overview)
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+300) { print("QA_WATCHDOG"); fflush(stdout); app.terminate(nil) }
        withExtendedLifetime(delegate) { app.run() }
    }
}
