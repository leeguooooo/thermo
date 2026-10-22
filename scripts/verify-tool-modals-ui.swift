// Production tool buttons in an owned native popover. Never starts hardware actions.
@testable import ThermoApp
import AppKit
import SwiftUI
import ThermoL10n
import ThermoKit

@MainActor final class ToolModalReview: NSObject, NSApplicationDelegate {
    let popover = NSPopover()
    var controls: NSWindow!
    var anchor: NSButton!
    var observer: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        controls.makeKeyAndOrderFront(nil)
    }
    @objc func showTools() {
        popover.contentViewController = NSHostingController(rootView: ReviewTools())
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }
    @objc func showPanel() {
        let monitor = AppModels.shared.monitor
        monitor.panelBodyHeightLimit = 640
        popover.contentViewController = NSHostingController(rootView: PopoverView(monitor: monitor))
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
        var initial: NSSize?
        for step in 0..<7 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step + 1)) { [weak self] in
                guard let self, self.popover.isShown,
                      let window = self.popover.contentViewController?.view.window else { return }
                let size = window.frame.size
                if initial == nil { initial = size }
                let unchanged = size == initial
                print("QA_PANEL_SIZE step=\(step) width=\(size.width) height=\(size.height) stable=\(unchanged)"); fflush(stdout)
                precondition(unchanged, "Live content resized the popover")
                monitor.lastError = step.isMultiple(of: 2) ? String(repeating: "Test readback unavailable. ", count: 30) : nil
                monitor.iconHidden = step.isMultiple(of: 2)
                monitor.publishSnapshot(Snapshot(temperatures: [], fans: step.isMultiple(of: 2) ? [] : [FanReading(id: 0, name: "QA", rpm: 2500, min: 2300, max: 6500, target: nil, manual: nil)], power: [], voltages: [], currents: [], battery: nil), parts: .everything)
            }
        }
    }
    @objc func showSettings() { MainWindow.show(.settings) }
    func applicationWillTerminate(_ notification: Notification) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        print("QA_EXIT"); fflush(stdout)
    }
}

private struct ReviewTools: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            CleanScreenButton(); AWDLButton(); IdleAwakeButton(); BatteryCareButton()
        }
        .environment(\.featureRowCompact, true)
        .padding(16).frame(width: 372).background(Theme.canvas)
        .environment(\.colorScheme, .dark)
    }
}

@main struct ToolModalUIAcceptance {
    @MainActor static func main() throws {
        guard Bundle.main.bundleIdentifier?.hasPrefix("dev.thermo.modalqa.") == true,
              let path = Bundle.main.object(forInfoDictionaryKey: "ThermoModalFixtureRoot") as? String else { exit(2) }
        let root = URL(fileURLWithPath: path)
        guard root.lastPathComponent.hasPrefix("thermo-modal-ui-"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".thermo-modal-ui-fixture").path) else { exit(3) }
        _ = freopen(root.appendingPathComponent("trace.log").path, "a", stdout)
        let language = Bundle.main.object(forInfoDictionaryKey: "ThermoModalFixtureLanguage") as? String ?? "zh-Hans"
        UserDefaults.standard.set(language, forKey: L10n.defaultsKey)
        L10n.apply(preference: language)
        Settings.register()
        AppModels.shared.monitor = Monitor(startMonitoring: false, helperInteraction: false)
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = ToolModalReview(); app.delegate = delegate
        delegate.controls = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 420, height: 160),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
        delegate.controls.title = "Thermo Modal QA controls"
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 12
        delegate.anchor = NSButton(title: "Show menu tools", target: delegate, action: #selector(ToolModalReview.showTools))
        stack.addArrangedSubview(delegate.anchor)
        stack.addArrangedSubview(NSButton(title: "Show live panel size test", target: delegate, action: #selector(ToolModalReview.showPanel)))
        stack.addArrangedSubview(NSButton(title: "Show settings", target: delegate, action: #selector(ToolModalReview.showSettings)))
        delegate.controls.contentView = stack
        delegate.popover.behavior = .transient; delegate.popover.animates = false
        delegate.popover.contentViewController = NSHostingController(rootView: ReviewTools())
        delegate.observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak delegate] note in
            MainActor.assumeIsolated {
                if let window = note.object as? NSWindow, window === MainWindow.window { delegate?.popover.performClose(nil) }
            }
        }
        let menu = NSMenu(), top = NSMenuItem(), items = NSMenu()
        let show = items.addItem(withTitle: "Show menu tools", action: #selector(ToolModalReview.showTools), keyEquivalent: "t"); show.target = delegate
        items.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        top.submenu = items; menu.addItem(top); app.mainMenu = menu
        print("QA_HELPER_AUTOMATION_DISABLED"); fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 900) { app.terminate(nil) }
        withExtendedLifetime(delegate) { app.run() }
    }
}
