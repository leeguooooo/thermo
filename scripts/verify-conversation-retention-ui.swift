// Three launches of one unchanged bundle verify UserDefaults-backed choice
// restoration. The scan is synthetic and the cleanup action is disconnected.
@testable import ThermoApp
import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

@_silgen_name("$s9ThermoApp20installStandardMenusyyF")
@MainActor func fixtureStandardMenus() {}

@MainActor struct RetentionFixture: View {
    @StateObject var model: DiskModel
    let root: URL
    let phase: String
    init(root: URL,phase: String) {
        self.root=root;self.phase=phase
        let home=root.appendingPathComponent("home").path
        let io=DiskScanIO(options:{ _,category,days in
            var value=ScanOptions(projectRoots:[]);value.home=home;value.discoverProjectRoots=false
            value.categories=category.map { [$0] } ?? [.aiSessions];value.sessionRetentionDays=days;return value
        },cached:{ _,_ in nil },scan:{ options,_,_,_ in
            print("QA_SCAN");fflush(stdout)
            var result=ScanReport(items:[],denied:[],started:Date(),duration:0)
            result.categories=[.aiSessions];result.sessionRetentionDays=options.sessionRetentionDays
            result.sessionPolicyVersion=ScanOptions.sessionPolicyVersion;result.language="zh-Hans";return result
        })
        _model=StateObject(wrappedValue:DiskModel(scanIO:io,requestNotifications:{},retentionPreferences:.stored(in:.standard)))
    }
    var body: some View {
        VStack {
            Text("独立验收：仅记住期限；不执行移除").font(.caption)
            DiskCategoryPage(model:model,category:.aiSessions,clean:{ print("QA_CLEAN_NOT_CONNECTED");fflush(stdout) })
        }.onAppear { record() }.onChange(of:model.sessionRetentionDays) { _ in record() }
            .preferredColorScheme(.dark)
    }
    private func record() {
        let value: [String:Any] = ["phase":phase,"days":model.sessionRetentionDays ?? -1,"selected":model.selected.count,
                                  "scanning":model.scanning,"hasReport":model.report != nil,
                                  "stored":UserDefaults.standard.data(forKey:ConversationRetentionPreferences.key) != nil]
        if let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]) {
            try? data.write(to:root.appendingPathComponent("receipt-"+phase+".json"),options:.atomic)
            print(String(decoding:data,as:UTF8.self));fflush(stdout)
        }
    }
}

@main @MainActor struct RetentionAcceptance: App {
    let root: URL
    let phase: String
    init() {
        guard CommandLine.arguments.count == 3 else { fatalError("fixture root and phase required") }
        root=URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath();phase=CommandLine.arguments[2]
        guard root.lastPathComponent.hasPrefix("thermo-retention-ui-"),["choose","restore","kept"].contains(phase),
              FileManager.default.fileExists(atPath:root.appendingPathComponent(".thermo-retention-ui-fixture").path),
              URL(fileURLWithPath:NSHomeDirectory()).resolvingSymlinksInPath() == root.appendingPathComponent("home") else { fatalError("owned private home required") }
        if phase == "choose" { UserDefaults.standard.removeObject(forKey:ConversationRetentionPreferences.key) }
        L10n.apply(preference:"zh-Hans")
    }
    var body: some Scene {
        WindowGroup("Thermo Retention QA") {
            RetentionFixture(root:root,phase:phase).frame(width:800,height:580).onAppear {
                NSApp.setActivationPolicy(.regular);NSApp.activate(ignoringOtherApps:true)
                DispatchQueue.main.asyncAfter(deadline:.now()+600) { NSApp.terminate(nil) }
            }
        }.defaultSize(width:800,height:580)
    }
}
