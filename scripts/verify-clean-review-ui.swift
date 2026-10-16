// Opt-in visible acceptance: link Debug testable ThermoApp and dependency objects.
// Launch with CFFIXED_USER_HOME set to an owned temporary Home containing
// .thermo-clean-ui-fixture. Tool commands are system true/false or touching an owned canary; no removal.
@testable import ThermoApp
import CleanKit
import ThermoL10n
import SwiftUI
import AppKit

@MainActor
struct CleanReviewFixture: View {
    @StateObject private var scope: DiskModel
    @StateObject private var partial: DiskModel
    @StateObject private var changing: DiskModel
    @State private var scenario = 0
    @State private var review: DiskCleanupReview?
    init(home: String) {
        func model(_ partial: Bool) -> DiskModel {
            let roots = (1...18).map { home + "/Library/Caches/Tool/very-long-reviewed-location-\($0)/package-cache" }
            let item = CleanItem(id: "ui-acceptance-" + (partial ? "partial" : "unknown"), category: .devCaches,
                title: partial ? "部分失败样本（true → false）" : "工具范围与未知大小样本", safety: .review,
                bytes: 1_000_000_000, note: "自有验收：仅运行系统 true/false，不删除数据。",
                commands: partial ? [["/usr/bin/true"], ["/usr/bin/false"]] : [["/usr/bin/true"]], commandScope: roots)
            var report = ScanReport(items: [item], denied: [], started: Date(), duration: 0)
            report.categories = [.devCaches]; report.language = L10n.current.rawValue
            let result = DiskModel(report: report); result.selected = [item.id]; return result
        }
        _scope = StateObject(wrappedValue: model(false)); _partial = StateObject(wrappedValue: model(true))
        let a = CleanItem(id: "race-a", category: .devCaches, title: "先前审阅 A", safety: .review, bytes: 100,
                          commands: [["/usr/bin/touch", home + "/canary-A"]])
        let b = CleanItem(id: "race-b", category: .devCaches, title: "后来选择 B", safety: .review, bytes: 200,
                          commands: [["/usr/bin/touch", home + "/canary-B"]])
        var raceReport = ScanReport(items: [a,b], denied: [], started: Date(), duration: 0)
        raceReport.categories = [.devCaches]; raceReport.language = L10n.current.rawValue
        let race = DiskModel(report: raceReport); race.selected = [a.id]
        _changing = StateObject(wrappedValue: race)
    }
    var model: DiskModel { scenario == 0 ? scope : scenario == 1 ? partial : changing }
    func startReview() {
        guard review == nil else { return }
        review = model.cleanupReview()
        if scenario == 2 {
            let target = changing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { target.selected = ["race-b"] }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("独立验收 · 无数据删除").font(.caption)
                Spacer()
                Picker("场景", selection: $scenario) { Text("范围与未知大小").tag(0); Text("部分失败").tag(1); Text("后台选择变化").tag(2) }
                    .pickerStyle(.segmented).frame(width: 300)
            }.padding(12)
            DiskCategoryPage(model: model, category: .devCaches, clean: startReview).id(scenario)
        }.background(Color(red: 0.08, green: 0.09, blue: 0.13)).preferredColorScheme(.dark)
        .sheet(item: $review) { frozen in
            DiskCleanConfirmation(review: frozen, confirm: { review = nil; model.clean(review: frozen) }, cancel: { review = nil })
        }
    }
}

@main
struct CleanReviewAcceptance {
    @MainActor static func main() {
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath()
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        guard home.path.hasPrefix(temporary.path + "/"),
              FileManager.default.fileExists(atPath: home.appendingPathComponent(".thermo-clean-ui-fixture").path) else {
            fputs("Requires an owned temporary fixture Home; no UI started.\n", stderr); exit(1)
        }
        L10n.apply(preference: "zh-Hans")
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let menu = NSMenu(), item = NSMenuItem(), submenu = NSMenu()
        submenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 580),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Thermo Clean Review QA"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CleanReviewFixture(home: home.path))
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { app.terminate(nil) }
        withExtendedLifetime(window) { app.run() }
    }
}
