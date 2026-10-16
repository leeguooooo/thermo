// Owns two direct children and a grandchild. Python fixture handles TERM by
// stopping its own sleep child; all three also have a 600-second exit limit.
@testable import ThermoApp
import AgentCore
import AppKit
import SwiftUI
import ThermoL10n

@MainActor final class DescendantsQA: NSObject, NSApplicationDelegate {
    let branch: Process
    let sibling: Process
    var branchLaunched=false,siblingLaunched=false
    init(branch: Process,sibling: Process) { self.branch=branch;self.sibling=sibling }
    func stopBranch() {
        guard branchLaunched else { return };branchLaunched=false
        if branch.isRunning { branch.terminate() };branch.waitUntilExit()
        print("QA_BRANCH_EXITED");fflush(stdout)
    }
    func applicationWillTerminate(_ notification: Notification) {
        stopBranch();guard siblingLaunched else { return };siblingLaunched=false
        if sibling.isRunning { sibling.terminate() };sibling.waitUntilExit()
        print("QA_CHILDREN_EXITED");fflush(stdout)
    }
}

@main struct DescendantsAcceptance {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("thermo-descendants-ui-"),
              FileManager.default.fileExists(atPath:root.appendingPathComponent(".thermo-descendants-ui-fixture").path) else { exit(3) }
        let branch=Process();branch.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        branch.arguments=["-I",root.appendingPathComponent("child.py").path,root.path]
        let sibling=Process();sibling.executableURL=URL(fileURLWithPath:"/bin/sleep");sibling.arguments=["600"]
        let delegate=DescendantsQA(branch:branch,sibling:sibling)
        defer { delegate.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification)) }
        for child in [branch,sibling] {
            child.standardOutput=FileHandle.nullDevice;child.standardError=FileHandle.nullDevice;try child.run()
            if child === branch { delegate.branchLaunched=true } else { delegate.siblingLaunched=true }
        }
        let ready=root.appendingPathComponent("children.json")
        let deadline=ProcessInfo.processInfo.systemUptime+5
        while !FileManager.default.fileExists(atPath:ready.path),branch.isRunning,ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval:0.02) }
        guard FileManager.default.fileExists(atPath:ready.path),let own=ProcessTable.identity(getpid()) else { return }
        L10n.apply(preference:"zh-Hans")
        let app=NSApplication.shared;app.delegate=delegate;app.setActivationPolicy(.regular)
        let menu=NSMenu(),item=NSMenuItem(),submenu=NSMenu()
        submenu.addItem(withTitle:"Quit",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        item.submenu=submenu;menu.addItem(item);app.mainMenu=menu
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:610),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="Thermo Descendants QA";window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:VStack {
            ProcessExplanationView(target:.init(identity:own))
            Button("结束第一个测试子树") { delegate.stopBranch() }.padding(.bottom,12)
        }.preferredColorScheme(.dark))
        window.center();window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
        print("QA_PIDS root=\(getpid()) branch=\(branch.processIdentifier) sibling=\(sibling.processIdentifier)");fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline:.now()+600) { app.terminate(nil) }
        withExtendedLifetime((window,delegate)) { app.run() }
    }
}
