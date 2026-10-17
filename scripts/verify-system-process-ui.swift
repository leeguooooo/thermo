// Read-only production process view for an explicitly selected root process.
@testable import ThermoApp
import AgentCore
import AppKit
import SwiftUI
import ThermoL10n

@main struct SystemProcessUIAcceptance {
    @MainActor static func main() throws {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "ThermoFixtureRoot") as? String,
              let pid = Bundle.main.object(forInfoDictionaryKey: "ThermoTargetPID") as? Int32 else { exit(2) }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("thermo-system-process-ui-"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".thermo-system-process-ui-fixture").path),
              let identity = ProcessTable.rootProcess(pid)?.sampledIdentity else { exit(3) }
        _ = freopen(root.appendingPathComponent("trace.log").path, "a", stdout)
        print("TARGET_ROOT_PID \(pid)"); fflush(stdout)
        L10n.apply(preference: "zh-Hans")
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let menu = NSMenu(), item = NSMenuItem(), submenu = NSMenu()
        submenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 640,height: 560),
                              styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        window.title = "Thermo System Process QA"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ProcessExplanationView(target: .init(identity: identity)).preferredColorScheme(.dark))
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now()+90) { app.terminate(nil) }
        withExtendedLifetime(window) { app.run() }
    }
}
