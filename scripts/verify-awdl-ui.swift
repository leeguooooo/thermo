// Production panel + model + coordinator; only the actuator and boot ID are fake.
// Never connects to launchd or invokes the system AWDL setter.
@testable import ThermoApp
import AppKit
import SwiftUI
import ThermoKit
import ThermoL10n

@_silgen_name("$s9ThermoApp20installStandardMenusyyF")
@MainActor func fixtureStandardMenus() {}

final class UIInterface: @unchecked Sendable {
    let root: URL
    let lock=NSLock()
    var up=true,allowRecovery=true,time=100.0
    init(_ root: URL) { self.root=root }
    func permit(_ value: Bool) { lock.lock();allowRecovery=value;lock.unlock() }
    func controller() -> AWDLSessionController {
        .init(io:.init(read:{ self.lock.lock();defer { self.lock.unlock() };return .init(index:15,up:self.up) },write:{ index,value in
            self.lock.lock();defer { self.lock.unlock() }
            guard index == 15 else { throw AWDLError("fixture identity changed") }
            if !value || self.allowRecovery { self.up=value }
            let data=try JSONSerialization.data(withJSONObject:["up":self.up,"index":15])
            try data.write(to:self.root.appendingPathComponent("interface.json"),options:.atomic)
            print("FAKE_WRITE requested=\(value) observed=\(self.up)");fflush(stdout)
        }),store:AWDLLeaseFile(directory:root.path,owner:getuid()).io,
              boot:{ "22222222-2222-2222-2222-222222222222" },clock:{ self.lock.lock();defer { self.lock.unlock() };return self.time })
    }
}

@MainActor final class UIDelegate: NSObject, NSApplicationDelegate {
    let model: AWDLModel
    init(_ model: AWDLModel) { self.model=model }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let blocked=model.requestQuit();print("QUIT_BLOCKED \(blocked)");fflush(stdout)
        return blocked ? .terminateCancel : .terminateNow
    }
}

@main struct AWDLUIAcceptance {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2,getuid() != 0 else { exit(2) }
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("thermo-awdl-ui-"),FileManager.default.fileExists(atPath:root.appendingPathComponent(".thermo-awdl-ui-fixture").path) else { exit(3) }
        let fake=UIInterface(root),owner=AWDLConnectionOwner()
        let network=AWDLHelperCoordinator(make:{ fake.controller() },tickInterval:0.1)
        let backend=AWDLBackend(read:{
            let data: Data=await withCheckedContinuation { continuation in network.state(owner:owner) { continuation.resume(returning:$0) } }
            return try PolicyCoding.decoder().decode(AWDLSessionState.self,from:data)
        },begin:{ seconds,id in
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                network.begin(owner:owner,seconds:seconds,sessionID:id) { error in
                    if let error { continuation.resume(throwing:AWDLError(error)) } else { continuation.resume() }
                }
            }
        },end:{
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                network.end(owner:owner) { error in
                    if let error { continuation.resume(throwing:AWDLError(error)) } else { continuation.resume() }
                }
            }
        },reset:{ network.disconnected(owner:owner) },record:{ action,status,_ in print("HISTORY \(action) \(status)");fflush(stdout) })
        let model=AWDLModel(backend:backend),delegate=UIDelegate(model)
        L10n.apply(preference:"zh-Hans")
        let app=NSApplication.shared;app.delegate=delegate;app.setActivationPolicy(.regular)
        let menu=NSMenu(),item=NSMenuItem(),submenu=NSMenu()
        submenu.addItem(withTitle:"Quit",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        item.submenu=submenu;menu.addItem(item);app.mainMenu=menu
        let window=NSWindow(contentRect:.init(x:0,y:0,width:620,height:650),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="Thermo AWDL UI QA";window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:VStack {
            Text("独立验收：模拟接口，不修改真实网络").font(.caption)
            HStack {
                Button("阻止模拟恢复") { fake.permit(false) }
                Button("允许模拟恢复") { fake.permit(true) }
            }
            AWDLPanel(model:model,configureHelper:{ print("NO_HELPER_INSTALL");fflush(stdout) })
        }.preferredColorScheme(.dark))
        window.center();window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
        DispatchQueue.main.asyncAfter(deadline:.now()+600) { fake.permit(true);app.terminate(nil) }
        withExtendedLifetime((window,delegate,network,fake)) { app.run() }
    }
}
