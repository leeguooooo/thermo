// Production process explanation with two owned, loopback-only child processes.
@testable import ThermoApp
import AgentCore
import AppKit
import SwiftUI
import ThermoL10n

@_silgen_name("$s9ThermoApp20installStandardMenusyyF")
@MainActor func tcpFixtureMenus() {
    let menu=NSMenu(),item=NSMenuItem(),submenu=NSMenu()
    submenu.addItem(withTitle:"Quit QA",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
    item.submenu=submenu;menu.addItem(item);NSApp.mainMenu=menu
}

@MainActor final class TCPFixtureDelegate: NSObject,NSApplicationDelegate {
    let children: [Process]
    init(_ children: [Process]) { self.children=children }
    func applicationWillTerminate(_ notification: Notification) {
        for child in children where child.isRunning { child.terminate() }
        for child in children { child.waitUntilExit() }
    }
}

@MainActor struct TCPFixtureSheetHost: View {
    let target: ProcessInspectionTarget
    @State private var showing: ProcessInspectionTarget?
    var body: some View {
        VStack(spacing:16) {
            Text("隔离 QA：仅自建回环进程")
            Button("打开进程详情") { showing=target }
        }
        .frame(width:640,height:560)
        .sheet(item:$showing) { ProcessExplanationView(target:$0) }
        .onAppear { showing=target }
    }
}

@main struct ProcessTCPAcceptance {
    @MainActor static func main() throws {
        let root=Bundle.main.bundleURL.deletingLastPathComponent().resolvingSymlinksInPath()
        guard getuid() != 0,root.lastPathComponent.hasPrefix("thermo-process-tcp-ui-"),
              FileManager.default.fileExists(atPath:root.appendingPathComponent(".thermo-process-tcp-ui").path) else { exit(2) }
        let helper=root.appendingPathComponent("server.py")
        guard FileManager.default.fileExists(atPath:helper.path) else { exit(3) }
        var children: [Process]=[]
        defer {
            for child in children where child.isRunning { child.terminate() }
            for child in children { child.waitUntilExit() }
        }
        for mode in ["target","sentinel"] {
            let child=Process();child.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
            child.arguments=[helper.path,root.path,mode];child.currentDirectoryURL=root
            child.standardOutput=FileHandle.nullDevice;child.standardError=FileHandle.nullDevice
            try child.run();children.append(child)
        }
        for _ in 0..<100 {
            if ["target.json","sentinel.json"].allSatisfy({ FileManager.default.fileExists(atPath:root.appendingPathComponent($0).path) }) { break }
            usleep(20_000)
        }
        let initial=try ["target.json","sentinel.json"].map { try Data(contentsOf:root.appendingPathComponent($0)) }
        guard initial.allSatisfy({ (try? JSONSerialization.jsonObject(with:$0) as? [String:Any])?["state"] as? String == "listening" }),
              let target=ProcessTable.identity(children[0].processIdentifier),
              let sentinel=ProcessTable.identity(children[1].processIdentifier) else { exit(4) }
        let metadata: [String:Any] = ["appPID":getpid(),"targetPID":target.pid,"sentinelPID":sentinel.pid,
            "target":try JSONSerialization.jsonObject(with:initial[0]),"sentinel":try JSONSerialization.jsonObject(with:initial[1])]
        try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys])
            .write(to:root.appendingPathComponent("initial.json"),options:.atomic)
        L10n.apply(preference:"zh-Hans")
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let delegate=TCPFixtureDelegate(children);app.delegate=delegate;tcpFixtureMenus()
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:560),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title="Thermo TCP Detail QA";window.isReleasedWhenClosed=false
        let inspection=ProcessInspectionTarget(identity:target,candidates:[sentinel])
        if FileManager.default.fileExists(atPath:root.appendingPathComponent("sheet-mode").path) {
            window.contentView=NSHostingView(rootView:TCPFixtureSheetHost(target:inspection).preferredColorScheme(.dark))
        } else {
            window.contentView=NSHostingView(rootView:ProcessExplanationView(target:inspection).preferredColorScheme(.dark))
        }
        window.center();window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
        DispatchQueue.main.asyncAfter(deadline:.now()+600) { app.terminate(nil) }
        withExtendedLifetime((window,delegate)) { app.run() }
    }
}
