// Production SpacePage and removal model, restricted to a marked, self-owned test home.
// Launch the generated bundle through computer-use; it takes no launch arguments.
@testable import ThermoApp
import AppKit
@testable import CleanKit
import SwiftUI
import ThermoL10n

@_silgen_name("$s9ThermoApp20installStandardMenusyyF")
@MainActor func spaceFixtureMenus() {
    let menu=NSMenu(),item=NSMenuItem(),submenu=NSMenu()
    submenu.addItem(withTitle:"Quit QA",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
    item.submenu=submenu;menu.addItem(item);NSApp.mainMenu=menu
}

@MainActor final class SpaceFixtureDelegate: NSObject,NSApplicationDelegate {
    let model: SpaceLensModel
    init(_ model: SpaceLensModel) { self.model=model }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.working ? .terminateCancel : .terminateNow
    }
}

@MainActor struct SpaceFixtureView: View {
    @ObservedObject var model: SpaceLensModel
    @State private var tab=SpaceTab.duplicates
    var body: some View { SpacePage(model:model,tab:$tab).preferredColorScheme(.dark) }
}

@main struct SpaceProtectionAcceptance {
    @MainActor static func main() throws {
        let root=Bundle.main.bundleURL.deletingLastPathComponent().resolvingSymlinksInPath()
        guard getuid() != 0,root.lastPathComponent.hasPrefix("thermo-space-protection-ui-"),
              FileManager.default.fileExists(atPath:root.appendingPathComponent(".thermo-space-protection-ui").path) else { exit(2) }
        let home=root.appendingPathComponent("home")
        guard FileManager.default.fileExists(atPath:home.appendingPathComponent("Downloads/01-keeper.bin").path),
              FileManager.default.fileExists(atPath:home.appendingPathComponent("Downloads/02-extra.bin").path) else { exit(3) }
        L10n.apply(preference:"zh-Hans")
        let model=SpaceLensModel(root:home.path,cache:home.appendingPathComponent(".qa-space-cache.json"),remove:{ paths,sizes,stateHome,incomplete,identities,required in
            guard FileManager.default.fileExists(atPath:root.appendingPathComponent("inject-record-failure").path) else {
                return ManualRemoval.trash(paths,sizes:sizes,home:stateHome,incompletePaths:incomplete,reviewIdentities:identities,requiredIdentities:required)
            }
            // Use a private test Trash. The actual move and record-write failure occur on disk;
            // this injection does not validate the macOS Trash service or history restoration.
            return ManualRemoval.trash(paths,sizes:sizes,home:stateHome,incompletePaths:incomplete,
                reviewIdentities:identities,requiredIdentities:required,move:{ selected in
                    guard selected == home.appendingPathComponent("Downloads/02-extra.bin").path else { throw NSError(domain:"QA",code:4) }
                    let trash=home.appendingPathComponent(".Trash")
                    try FileManager.default.createDirectory(at:trash,withIntermediateDirectories:true)
                    let destination=trash.appendingPathComponent(UUID().uuidString+".bin")
                    try FileManager.default.moveItem(atPath:selected,toPath:destination.path)
                    let value=["original":selected,"destination":destination.path,"identity":FileIdentity.of(destination.path) ?? ""]
                    try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys])
                        .write(to:root.appendingPathComponent("injected-move.json"),options:.atomic)
                    return destination
                })
        })
        let app=NSApplication.shared;app.setActivationPolicy(.regular)
        let delegate=SpaceFixtureDelegate(model);app.delegate=delegate;spaceFixtureMenus()
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:580),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title="Thermo Space Protection QA";window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:SpaceFixtureView(model:model))
        window.center();window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)
        func receipt() {
            let value: [String:Any] = ["pid":getpid(),"scanning":model.scanning,"working":model.working,
                "findingDuplicates":model.findingDuplicates,"selected":model.basket.keys.sorted(),
                "groups":model.duplicates?.map(\.paths) ?? [],"outcome":model.outcome ?? "", "warning":model.outcomeIsWarning]
            if let data=try? JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]) {
                try? data.write(to:root.appendingPathComponent("receipt.json"),options:.atomic)
            }
        }
        let timer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { _ in MainActor.assumeIsolated { receipt() } }
        DispatchQueue.main.asyncAfter(deadline:.now()+600) { if !model.working { receipt();app.terminate(nil) } }
        withExtendedLifetime((window,delegate,timer)) { app.run() }
    }
}
