// Private-home native acceptance. No TCC changes. Active sessions have a separate
// approximately 20-second QA watchdog; the production timeout remains unchanged.
@testable import ThermoApp
import AppKit
import ApplicationServices
import Carbon
import SwiftUI
import ThermoL10n

@_silgen_name("$s9ThermoApp20installStandardMenusyyF")
@MainActor func fixtureStandardMenus() {}

func ownTapCount() -> Int {
    var count: UInt32=0
    guard CGGetEventTapList(0,nil,&count) == .success,count<=4096 else { return -1 }
    if count == 0 { return 0 }
    var records=[CGEventTapInformation](repeating:.init(),count:Int(count)),actual:UInt32=0
    let result=records.withUnsafeMutableBufferPointer { CGGetEventTapList(count,$0.baseAddress,&actual) }
    guard result == .success,actual<=count else { return -1 }
    return records.prefix(Int(actual)).filter { $0.tappingProcess == getpid() }.count
}

@MainActor struct ShortcutFixture: View {
    @ObservedObject var screen=CleanScreenModel.shared
    @ObservedObject var shortcut=CleanScreenShortcutModel.shared
    @State private var showing=true
    @State private var value=""
    @State private var watchdog=UUID()
    @State private var activation: NSObjectProtocol?
    var body: some View {
        VStack(spacing:16) {
            Text("快捷键独立验收：私有偏好、约 20 秒恢复保护").font(.headline)
            Text(screen.active ? "Active" : "Idle")
            Text(shortcut.binding?.label ?? "Off")
            TextField("退出后输入 b",text:$value).textFieldStyle(.roundedBorder).frame(width:280)
            Button("打开清屏设置") { showing=true }
            Button("验证冲突保留") { conflictProbe() }.disabled(shortcut.binding == nil)
        }.padding(24).frame(width:560,height:300)
            .sheet(isPresented:$showing) { CleanScreenSetupView(model:screen) }
            .onAppear {
                NSApp.setActivationPolicy(.regular);NSApp.activate(ignoringOtherApps:true)
                activation=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) { note in
                    if let app=note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                        print("FRONT \(app.bundleIdentifier ?? "unknown")");fflush(stdout)
                    }
                }
            }.onDisappear {
                if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) };activation=nil
            }.onChange(of:shortcut.binding) { key in
                print("BINDING \(key?.label ?? "Off") stored=\(UserDefaults.standard.data(forKey:CleanScreenShortcutModel.preferenceKey) != nil)");fflush(stdout)
            }.onChange(of:screen.active) { active in
                let token=UUID();watchdog=token
                print("ACTIVE \(active) taps=\(ownTapCount()) overlays=\(NSApp.windows.filter { $0.isVisible && $0.level == .screenSaver }.count) cause=\(screen.interruption?.rawValue ?? "none")");fflush(stdout)
                if active {
                    DispatchQueue.main.asyncAfter(deadline:.now()+20) {
                        if watchdog == token,screen.active { print("QA_WATCHDOG");fflush(stdout);screen.stop() }
                    }
                }
            }
    }
    private func conflictProbe() {
        guard let old=shortcut.binding else { return }
        let data=UserDefaults.standard.data(forKey:CleanScreenShortcutModel.preferenceKey)
        let candidate=CleanScreenKeyBinding(keyCode:80,modifiers:CleanScreenKeyBinding.allowed,keyLabel:"F19")
        var ref:EventHotKeyRef?
        let status=RegisterEventHotKey(candidate.keyCode,candidate.modifiers,.init(signature:0x5154484B,id:1),GetApplicationEventTarget(),0,&ref)
        guard status == noErr,let ref else { print("CONFLICT_SETUP_FAILED \(status)");fflush(stdout);return }
        defer { print("CONFLICT_RESERVATION_RELEASE \(UnregisterEventHotKey(ref))");fflush(stdout) }
        shortcut.apply(candidate)
        print("CONFLICT_PRESERVED \(shortcut.binding == old && UserDefaults.standard.data(forKey:CleanScreenShortcutModel.preferenceKey) == data) issue=\(shortcut.issue != nil)");fflush(stdout)
        if shortcut.binding != old { shortcut.apply(old) }
    }
}

@main @MainActor struct ShortcutAcceptance: App {
    init() {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("thermo-shortcut-ui-"),FileManager.default.fileExists(atPath:root.appendingPathComponent(".thermo-shortcut-ui-fixture").path),
              URL(fileURLWithPath:NSHomeDirectory()).resolvingSymlinksInPath() == root.appendingPathComponent("home").resolvingSymlinksInPath() else { fatalError("isolated home required") }
        L10n.apply(preference:"zh-Hans")
        UserDefaults.standard.removeObject(forKey:CleanScreenShortcutModel.preferenceKey)
        UserDefaults.standard.set(CleanScreenDuration.oneMinute.rawValue,forKey:CleanScreenDuration.preferenceKey)
        print("AX_TRUSTED \(AXIsProcessTrusted()) baselineTaps=\(ownTapCount())");fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline:.now()+600) { NSApp.terminate(nil) }
    }
    var body: some Scene { WindowGroup("Thermo Shortcut QA") { ShortcutFixture().preferredColorScheme(.dark) } }
}
