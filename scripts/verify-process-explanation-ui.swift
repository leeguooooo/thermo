// Owned, read-only UI acceptance. The short-lived child only requests idle-sleep prevention.
@testable import ThermoApp
import AgentCore
import AppKit
import SwiftUI
import ThermoL10n

@MainActor final class ProcessQADelegate: NSObject, NSApplicationDelegate {
    let child: Process
    init(_ child: Process) { self.child=child }
    func applicationWillTerminate(_ notification: Notification) {
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
    }
}

@main struct ProcessExplanationAcceptance {
    @MainActor static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("thermo-process-ui-"), FileManager.default.fileExists(atPath:root.appendingPathComponent(".thermo-process-ui-fixture").path) else { exit(2) }
        L10n.apply(preference:"zh-Hans")
        let child=Process();child.executableURL=URL(fileURLWithPath:"/usr/bin/caffeinate");child.arguments=["-i","-t","600"]
        child.standardOutput=FileHandle.nullDevice;child.standardError=FileHandle.nullDevice
        try child.run()
        print("QA_CHILD_PID \(child.processIdentifier)");fflush(stdout)
        defer { if child.isRunning { child.terminate() };child.waitUntilExit() }
        guard let own=ProcessTable.identity(getpid()) else { exit(3) }
        let options=[ProcessTable.identity(child.processIdentifier)].compactMap { $0 }
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let delegate=ProcessQADelegate(child);app.delegate=delegate
        let menu=NSMenu(), item=NSMenuItem(), submenu=NSMenu()
        submenu.addItem(withTitle:"Quit",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        item.submenu=submenu;menu.addItem(item);app.mainMenu=menu
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:560),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="Thermo Process Explanation QA";window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:ProcessExplanationView(target:.init(identity:own,candidates:options)).preferredColorScheme(.dark))
        window.center();window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
        func reportWindow() {
            print("QA_WINDOW pid=\(getpid()) number=\(window.windowNumber) visible=\(window.isVisible) activeSpace=\(window.isOnActiveSpace) width=\(window.frame.width) height=\(window.frame.height) screen=\(window.screen != nil)")
            fflush(stdout)
        }
        reportWindow()
        DispatchQueue.main.asyncAfter(deadline:.now()+1) { reportWindow() }
        DispatchQueue.main.asyncAfter(deadline:.now()+600) { app.terminate(nil) }
        withExtendedLifetime((window,delegate)) { app.run() }
    }
}
