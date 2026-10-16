// Owned cache fixture. A gate simulates blocked storage; only the wrapper buttons
// control that gate. The category, scan and stop controls are production views.
@testable import ThermoApp
import AppKit
import CleanKit
import SwiftUI
import ThermoL10n

@_silgen_name("$s9ThermoApp20installStandardMenusyyF")
@MainActor func fixtureStandardMenus() {}

final class DiskReadGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var reads = 0, scans = 0
    func read() {
        lock.lock(); reads += 1; let count = reads; lock.unlock()
        print("CACHE_BEGIN \(count) main=\(Thread.isMainThread)"); fflush(stdout)
        _ = release.wait(timeout: .now() + 300)
    }
    func scan() {
        lock.lock(); scans += 1; lock.unlock()
        print("SCAN_STARTED main=\(Thread.isMainThread)"); fflush(stdout)
    }
}

@MainActor struct DiskBackgroundFixture: View {
    @StateObject var model: DiskModel
    @State private var clicks = 0
    let gate: DiskReadGate
    init(home: String, gate: DiskReadGate) {
        self.gate = gate
        let io = DiskScanIO(options: { _, category, _ in
            var options = ScanOptions(projectRoots: [])
            options.home = home; options.discoverProjectRoots = false
            options.categories = category.map { [$0] } ?? [.devCaches]
            return options
        }, cached: { options, language in
            gate.read()
            return DiskScanIO.live.cached(options, language)
        }, scan: { options, cancellation, progress, items in
            gate.scan()
            return DiskScanIO.live.scan(options, cancellation, progress, items)
        })
        _model = StateObject(wrappedValue: DiskModel(scanIO: io, requestNotifications: {}))
    }
    var body: some View {
        VStack {
            Text("独立验收：私有缓存；清理确认未连接执行").font(.caption)
            HStack {
                Button("界面计数 \(clicks)") { clicks += 1; print("UI_CLICK \(clicks)"); fflush(stdout) }
                Button("释放缓存读取") { gate.release.signal() }
                Button("重新演练") { model.protectionRulesChanged(); model.loadSaved(category: .devCaches) }
            }.padding(8)
            DiskCategoryPage(model: model, category: .devCaches, clean: {})
        }.onChange(of: model.scanning) { value in
            print("SCANNING \(value) cancelled=\(model.report?.cancelled == true)"); fflush(stdout)
        }.preferredColorScheme(.dark)
    }
}

@main @MainActor struct DiskBackgroundAcceptance: App {
    let home: String
    let gate = DiskReadGate()
    init() {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix("thermo-disk-ui-"), FileManager.default.fileExists(atPath:root.appendingPathComponent(".thermo-disk-ui-fixture").path) else { fatalError("owned fixture marker required") }
        home = root.appendingPathComponent("home").path
        L10n.apply(preference: "zh-Hans")
        var report = ScanReport(items: [.init(id:"fixture-cache",category:.devCaches,title:"自有缓存读取样本",safety:.review,bytes:10,paths:[home+"/fixture-cache"])],denied:[],started:Date(),duration:0)
        report.language = "zh-Hans"; report.categories = [.devCaches]; report.projectRoots = []
        report.discoverProjectRoots = false; report.olderThanDays = 30
        report.sessionPolicyVersion = ScanOptions.sessionPolicyVersion
        ScanReportCache.save(report, home: home)
    }
    var body: some Scene {
        WindowGroup("Thermo Disk Background QA") {
            DiskBackgroundFixture(home: home, gate: gate).frame(width:800,height:580).onAppear {
                NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true)
                DispatchQueue.main.asyncAfter(deadline:.now()+600) { gate.release.signal(); NSApp.terminate(nil) }
            }
        }.defaultSize(width:800,height:580)
    }
}
