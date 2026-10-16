// Opt-in native source-discovery presentation acceptance. Link Debug testable App objects.
// Requires an owned temporary CFFIXED_USER_HOME and .thermo-source-ui-fixture marker.
// Reports and feed checks are injected; no real feeds, application launch or install.
@testable import ThermoApp
@testable import CleanKit
import AppKit
import SwiftUI
import ThermoL10n

@MainActor
struct SourceScenario: View {
    @StateObject private var model: NativeUpdatesModel
    init(_ scenario: Int, home: String) {
        let issue = AppInventoryIssue("Could not inspect application directory", path: home + "/Unreadable Applications")
        let source = NativeUpdateSource(app: .init(path: home + "/Known.app", name: "已确认的来源样本", bundleID: "com.example.known"), kind: "sparkle", feedHost: "updates.example.test")
        let report: NativeUpdateSourcesReport
        switch scenario {
        case 0: report = .init(sources: [], issues: [issue])
        case 1: report = .init(sources: [source], issues: [issue])
        default: report = .init(sources: [])
        }
        _model = StateObject(wrappedValue: NativeUpdatesModel(discovery: { _ in report }, checker: {
            .init(source: $0, status: "noNewerCompatibleVersion", message: "离线替身检查已完成；未访问更新服务器。")
        }))
    }
    var body: some View { NativeUpdatesPanel(model: model) }
}

@MainActor
struct SourceDiscoveryFixture: View {
    let home: String
    @State private var scenario = 0
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("独立验收 · 无网络、无安装").font(.caption)
                Spacer()
                Picker("场景", selection: $scenario) {
                    Text("未读完整的空表").tag(0)
                    Text("已知来源与读取问题").tag(1)
                    Text("确认空结果").tag(2)
                }.pickerStyle(.segmented).frame(width: 430)
            }
            SourceScenario(scenario, home: home).id(scenario)
        }.padding(20).preferredColorScheme(.dark)
    }
}

@main struct SourceDiscoveryAcceptance {
    @MainActor static func main() {
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        guard home.path.hasPrefix(temp.path + "/"), FileManager.default.fileExists(atPath: home.appendingPathComponent(".thermo-source-ui-fixture").path) else {
            fputs("Requires an owned temporary source-discovery fixture Home.\n", stderr); exit(1)
        }
        L10n.apply(preference: "zh-Hans")
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let menu = NSMenu(), item = NSMenuItem(), submenu = NSMenu()
        submenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 580), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        window.title = "Thermo Update Source QA"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SourceDiscoveryFixture(home: home.path))
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { app.terminate(nil) }
        withExtendedLifetime(window) { app.run() }
    }
}
