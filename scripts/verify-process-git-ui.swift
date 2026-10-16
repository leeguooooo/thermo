// Owned, read-only acceptance of the live process inspector. Launch from the
// temporary fixture repository; it never changes cwd, Git metadata or TCC.
@testable import ThermoApp
import AgentCore
import AppKit
import SwiftUI
import ThermoL10n

@main struct ProcessGitAcceptance {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("thermo-process-git-ui-"),
              FileManager.default.fileExists(atPath:root.appendingPathComponent(".thermo-process-git-ui-fixture").path),
              URL(fileURLWithPath:FileManager.default.currentDirectoryPath).resolvingSymlinksInPath() == root.appendingPathComponent("repository"),
              let own=ProcessTable.identity(getpid()) else { exit(3) }
        L10n.apply(preference:"zh-Hans")
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let menu=NSMenu(),item=NSMenuItem(),submenu=NSMenu()
        submenu.addItem(withTitle:"Quit",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        item.submenu=submenu;menu.addItem(item);app.mainMenu=menu
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:560),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="Thermo Git Context QA";window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:ProcessExplanationView(target:.init(identity:own)).preferredColorScheme(.dark))
        window.center();window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
        print("QA_PROCESS \(getpid())");fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline:.now()+600) { app.terminate(nil) }
        withExtendedLifetime(window) { app.run() }
    }
}
