// Owned, opt-in recovery presentation fixture. Dummy directories, no app install or execution.
@testable import ThermoApp
@testable import CleanKit
import AppKit
import SwiftUI
import ThermoL10n

@MainActor struct BackupScenario: View {
    @StateObject var model: NativeUpdatesModel
    init(_ scenario: Int, home: String) {
        _model = StateObject(wrappedValue: NativeUpdatesModel(read:{ _ in [] }, recoveryReader: {
            var report = NativeUpdateTransaction.recovery(home:home)
            if scenario != 0, let old = report.backups?.first {
                report.backups = [.init(id:old.id,path:old.path,allocatedBytes:scenario == 1 ? 2_147_483_648 : nil,
                    complete:false,issue:scenario == 1 ? "Preserved app size is incomplete; the shown usage is a lower bound" : "Preserved app size could not be measured")]
            }
            return report
        }))
    }
    var body: some View { NativeUpdateRecoveryView(model:model) }
}
@MainActor struct BackupFixture: View {
    let home: String
    @State var scenario = 0
    var body: some View {
        VStack {
            Text("独立验收：真实夹具测量 / 注入下限与未知；不安装或删除应用").font(.caption)
            Picker("场景",selection:$scenario) {
                Text("完整测量").tag(0); Text("测量下限").tag(1); Text("大小未知").tag(2)
            }.pickerStyle(.segmented)
            BackupScenario(scenario,home:home).id(scenario)
        }.padding(14).preferredColorScheme(.dark)
    }
}
@main struct BackupAcceptance {
    @MainActor static func main() throws {
        let home = URL(fileURLWithPath:NSHomeDirectory()).resolvingSymlinksInPath().path
        guard home.contains("/thermo-backup-ui-"), FileManager.default.fileExists(atPath:home+"/.thermo-backup-ui-fixture") else { exit(2) }
        let id = UUID().uuidString, target = home+"/Applications/Fixture.app"
        let backup = home+"/Applications/.thermo-update-"+id+"/previous.app"
        for path in [target,backup+"/Contents"] { try FileManager.default.createDirectory(atPath:path,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]) }
        try Data(repeating:42,count:8192).write(to:URL(fileURLWithPath:backup+"/Contents/payload"))
        let before = NativeBundleFacts(bundleID:"com.example.fixture",version:"1.0",build:"1",team:nil,architectures:["arm64"],seal:"fixture-old")
        let after = NativeBundleFacts(bundleID:"com.example.fixture",version:"2.0",build:"2",team:nil,architectures:["arm64"],seal:"fixture-new")
        guard let oldID = FileIdentity.of(backup), let newID = FileIdentity.of(target) else { exit(2) }
        try NativeUpdateTransaction.save(.init(id:id,target:target,backup:backup,phase:"installed",original:before,replacement:after,originalID:oldID,replacementID:newID),home:home)
        L10n.apply(preference:"zh-Hans")
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let menu = NSMenu(), item = NSMenuItem(), submenu = NSMenu()
        submenu.addItem(withTitle:"Quit",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:580),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "Thermo Backup QA"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:BackupFixture(home:home))
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps:true)
        DispatchQueue.main.asyncAfter(deadline:.now()+600) { app.terminate(nil) }
        withExtendedLifetime(window) { app.run() }
    }
}
