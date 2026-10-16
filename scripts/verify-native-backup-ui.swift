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
    @State var page = 0
    @StateObject var history = HistoryModel()
    @StateObject var disk = DiskModel()
    init(home: String, initialPage: Int = 0) { self.home=home;_page=State(initialValue:initialPage) }
    var body: some View {
        VStack {
            Text("独立验收：自有签名夹具；仅移入废纸篓与恢复，不安装真实应用").font(.caption)
            Picker("场景",selection:$scenario) {
                Text("完整测量").tag(0); Text("测量下限").tag(1); Text("大小未知").tag(2)
            }.pickerStyle(.segmented)
            Picker("验收页面",selection:$page) {
                Text("备份").tag(0);Text("历史恢复").tag(1);Text("聊天期限（只读）").tag(2)
            }.pickerStyle(.segmented)
            if page == 0 { BackupScenario(scenario,home:home).id(scenario) }
            else if page == 1 { HistoryPage(model:history,open:{ _ in }) }
            else { DiskCategoryPage(model:disk,category:.aiSessions,clean:{}) }

        }.padding(14).preferredColorScheme(.dark)
    }
}
@MainActor enum BackupFixtureSetup {
    static func prepare() throws -> String {
        let home = URL(fileURLWithPath:NSHomeDirectory()).resolvingSymlinksInPath().path
        guard home.contains("/thermo-backup-ui-"), FileManager.default.fileExists(atPath:home+"/.thermo-backup-ui-fixture") else { exit(2) }
        let sessions=home+"/.codex/sessions/2026/01/01"
        try FileManager.default.createDirectory(atPath:sessions,withIntermediateDirectories:true)
        let chat=sessions+"/rollout-owned-old.jsonl"
        try Data(("{\"type\":\"session_meta\",\"payload\":{\"id\":\"owned-old\",\"cwd\":\""+home+"/missing-project\"}}\n").utf8).write(to:URL(fileURLWithPath:chat))
        try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(-100*86400)],ofItemAtPath:chat)
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
        return home
    }
}

@main @MainActor struct BackupAcceptance: App {
    private let home: String
    init() {
        do { home=try BackupFixtureSetup.prepare() }
        catch { fatalError("Owned fixture setup failed: \(error)") }
    }
    var body: some Scene {
        WindowGroup("Thermo Recovery QA") {
            BackupFixture(home:home,initialPage:CommandLine.arguments.contains("--conversations") ? 2 : 0).frame(width:800,height:580)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps:true)
                    DispatchQueue.main.asyncAfter(deadline:.now()+1800) { NSApp.terminate(nil) }
                }
        }.defaultSize(width:800,height:580)
    }
}
