// Owned native acceptance. No permission request or TCC change. Starting is a
// deliberate UI action; an independent QA timer ends any active mode after 20 s.
@testable import ThermoApp
import ApplicationServices
import AppKit
import SwiftUI
import ThermoL10n

@_silgen_name("$s9ThermoApp20installStandardMenusyyF")
@MainActor func fixtureStandardMenus() {}

func ownTapCount() -> Int {
    var count: UInt32 = 0
    guard CGGetEventTapList(0,nil,&count) == .success,count <= 4096 else { return -1 }
    if count == 0 { return 0 }
    var entries = [CGEventTapInformation](repeating:CGEventTapInformation(),count:Int(count)), actual: UInt32 = 0
    let result = entries.withUnsafeMutableBufferPointer { CGGetEventTapList(count,$0.baseAddress,&actual) }
    guard result == .success,actual <= count else { return -1 }
    return entries.prefix(Int(actual)).filter { $0.tappingProcess == getpid() }.count
}

@MainActor struct CleanScreenFixture: View {
    @ObservedObject var model = CleanScreenModel.shared
    @State private var showing = true
    @State private var text = ""
    @State private var localMonitor: Any?
    var body: some View {
        VStack(spacing:18) {
            Text("独立清屏验收：仅使用已有权限，20 秒后自动结束").font(.headline)
            Text(model.active ? "Active" : "Idle")
            TextField("退出后输入 b 验证恢复",text:$text).textFieldStyle(.roundedBorder).frame(width:320)
            Button("打开清屏设置") { showing = true }
        }.padding(24).frame(width:560,height:240)
            .sheet(isPresented:$showing) { CleanScreenSetupView(model:model) }
            .onAppear {
                NSApp.setActivationPolicy(.regular);NSApp.activate(ignoringOtherApps:true)
                localMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { event in
                    print("LOCAL_KEY_DOWN");fflush(stdout);return event
                }
            }.onDisappear {
                if let localMonitor { NSEvent.removeMonitor(localMonitor) };localMonitor = nil
            }.onChange(of:model.active) { active in
                print("TIME \(Date().timeIntervalSince1970) ACTIVE \(active) taps=\(ownTapCount()) overlays=\(NSApp.windows.filter { $0.isVisible && $0.level == .screenSaver }.count) cause=\(model.interruption?.rawValue ?? "none") completed=\(String(describing:model.finished))");fflush(stdout)
                if active {
                    DispatchQueue.main.asyncAfter(deadline:.now()+20) {
                        if model.active { print("QA_WATCHDOG");fflush(stdout);model.stop() }
                    }
                }
            }
    }
}

@main @MainActor struct CleanScreenAcceptance: App {
    init() {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("thermo-screen-ui-"),FileManager.default.fileExists(atPath:root.appendingPathComponent(".thermo-screen-ui-fixture").path) else { fatalError("owned fixture required") }
        L10n.apply(preference:"zh-Hans")
        print("AX_TRUSTED \(AXIsProcessTrusted()) baselineTaps=\(ownTapCount()) screens=\(NSScreen.screens.count)");fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline:.now()+600) { CleanScreenModel.shared.stop();NSApp.terminate(nil) }
    }
    var body: some Scene {
        WindowGroup("Thermo Clean Screen QA") { CleanScreenFixture().preferredColorScheme(.dark) }
            .defaultSize(width:560,height:240)
    }
}
