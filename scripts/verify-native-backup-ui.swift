// Owned, opt-in recovery/Trash fixture. Ad-hoc signed apps; their executables are never launched.
@testable import ThermoApp
@testable import CleanKit
import AppKit
import AgentCore
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
    @StateObject var history = HistoryModel()
    var body: some View {
        VStack {
            Text("独立验收：自有签名夹具；仅移入废纸篓与恢复，不安装真实应用").font(.caption)
            Picker("场景",selection:$scenario) {
                Text("完整测量").tag(0); Text("测量下限").tag(1); Text("大小未知").tag(2)
            }.pickerStyle(.segmented)
            TabView {
                BackupScenario(scenario,home:home).id(scenario).tabItem { Text("备份") }
                HistoryPage(model:history,open:{ _ in }).tabItem { Text("历史恢复") }
            }
        }.padding(14).preferredColorScheme(.dark)
    }
}
@main struct BackupAcceptance {
    @MainActor static func main() throws {
        let home = URL(fileURLWithPath:NSHomeDirectory()).resolvingSymlinksInPath().path
        guard home.contains("/thermo-backup-ui-"), FileManager.default.fileExists(atPath:home+"/.thermo-backup-ui-fixture") else { exit(2) }
        let id = UUID().uuidString, target = home+"/Applications/Fixture.app"
        let backup = home+"/Applications/.thermo-update-"+id+"/previous.app"
        let source = home+"/fixture.c", executable = home+"/fixture-tool"
        try Data("int main(void) { return 0; }\n".utf8).write(to:URL(fileURLWithPath:source))
        let compiled = CommandRunner.run("/usr/bin/clang",arguments:["-arch","arm64",source,"-o",executable],timeout:30)
        guard compiled.status == 0 else { exit(3) }
        func makeApp(_ path: String, version: String, build: String) throws {
            for suffix in ["/Contents/MacOS","/Contents/Resources"] {
                try FileManager.default.createDirectory(atPath:path+suffix,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            }
            try FileManager.default.copyItem(atPath:executable,toPath:path+"/Contents/MacOS/Fixture")
            let info: [String:Any] = ["CFBundleIdentifier":"com.example.fixture","CFBundleExecutable":"Fixture","CFBundlePackageType":"APPL","CFBundleVersion":build,"CFBundleShortVersionString":version]
            try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:URL(fileURLWithPath:path+"/Contents/Info.plist"))
            try Data(repeating:42,count:8192).write(to:URL(fileURLWithPath:path+"/Contents/Resources/payload"))
            let signed = CommandRunner.run("/usr/bin/codesign",arguments:["--force","--sign","-",path],timeout:30)
            guard signed.status == 0 else { exit(3) }
        }
        try FileManager.default.createDirectory(atPath:(backup as NSString).deletingLastPathComponent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try makeApp(target,version:"2.0",build:"200"); try makeApp(backup,version:"1.0",build:"100")
        let before = try NativeBundleValidation.facts(backup), after = try NativeBundleValidation.facts(target)
        guard let oldID = FileIdentity.of(backup), let newID = FileIdentity.of(target) else { exit(2) }
        try NativeUpdateTransaction.save(.init(id:id,target:target,backup:backup,phase:"installed",original:before,replacement:after,originalID:oldID,replacementID:newID),home:home)
        L10n.apply(preference:"zh-Hans")
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let menu = NSMenu(), item = NSMenuItem(), submenu = NSMenu()
        submenu.addItem(withTitle:"Quit",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:580),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "Thermo Backup QA"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:BackupFixture(home:home).frame(width:800,height:580))
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps:true)
        DispatchQueue.main.asyncAfter(deadline:.now()+600) { app.terminate(nil) }
        withExtendedLifetime(window) { app.run() }
    }
}
