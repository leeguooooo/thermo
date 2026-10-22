// Link against the optimized testable app module. This entry point never starts AppDelegate.
@testable import ThermoApp
import AgentCore
import AppKit
import Darwin
import Foundation
import SwiftUI

@MainActor final class PerformanceReview: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let root: URL
    let monitor: Monitor
    let popover = NSPopover()
    var status: NSStatusItem!
    var timer: Timer?
    var observer: NSObjectProtocol?
    var started = Date()
    init(root: URL, monitor: Monitor) { self.root = root; self.monitor = monitor }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), top = NSMenuItem(), commands = NSMenu()
        for (title, action, key) in [("Show console", #selector(showConsole), "o"),
                                     ("Show menu panel", #selector(showPanel), "p"),
                                     ("Quit performance QA", #selector(NSApplication.terminate(_:)), "q")] {
            let item = commands.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        }
        top.submenu = commands; menu.addItem(top); NSApp.mainMenu = menu
        installStandardMenus()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "PQ"
        status.button?.setAccessibilityLabel("Thermo Performance QA")
        status.button?.target = self; status.button?.action = #selector(showPanel)
        popover.behavior = .transient; popover.animates = false; popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView(monitor: monitor))
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                if let window = note.object as? NSWindow, window === MainWindow.window { self?.popover.performClose(nil) }
            }
        }
        showConsole()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.record() }
        }
        print("PERFORMANCE_QA helper/shortcuts/recorder/app-control startup disabled"); fflush(stdout)
    }
    @objc func showConsole() {
        MainWindow.show()

    }
    @objc func showPanel() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = status.button else { return }
        monitor.popoverOpen = true; PanelModel.shared.setActive(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func popoverDidClose(_ notification: Notification) { monitor.popoverOpen = false; PanelModel.shared.setActive(false) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showConsole(); return false }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); if let observer { NotificationCenter.default.removeObserver(observer) }
        record(); print("PERFORMANCE_QA_EXIT"); fflush(stdout)
    }
    func record() {
        var usage = rusage(); guard getrusage(RUSAGE_SELF, &usage) == 0 else { return }
        let memory = ProcessTable.memory(getpid())
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)/1e6
        let value: [String: Any] = ["at": Date().timeIntervalSince1970, "pid": getpid(), "elapsed": Date().timeIntervalSince(started),
            "cpuSeconds": cpu, "footprintKB": memory.footprintKB ?? -1, "rssKB": memory.residentKB ?? -1,
            "page": String(describing: MainWindow.state.page),
            "windowVisible": monitor.windowOpen, "windowIsVisible": MainWindow.window?.isVisible ?? false,
            "windowMinimized": MainWindow.window?.isMiniaturized ?? false, "panelOpen": monitor.popoverOpen,
            "cpuSampling": ComputeModel.cpu.samplingActive, "gpuSampling": ComputeModel.shared.samplingActive,
            "memorySampling": MemoryModel.shared.samplingActive, "panelSampling": PanelModel.shared.samplingActive,
            "pulseSampling": SystemPulse.shared.samplingActive, "pulseHolders": SystemPulse.shared.holderCount,
            "controllerAlive": MainWindow.window?.contentViewController != nil,
            "historyPoints": monitor.history.count]
        guard var data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) else { return }
        data.append(10)
        let path = root.appendingPathComponent("samples.jsonl")
        if let file = try? FileHandle(forWritingTo: path) { defer { try? file.close() }; _ = try? file.seekToEnd(); try? file.write(contentsOf: data) }
        else { try? data.write(to: path) }
    }
}

@main struct ThermoPerformanceUI {
    @MainActor static func main() {
        guard Bundle.main.bundleIdentifier == "dev.thermo.perfreview.01a1612a",
              let path = Bundle.main.object(forInfoDictionaryKey: "ThermoPerformanceFixture") as? String else { exit(2) }
        let root = URL(fileURLWithPath: path)
        guard root.lastPathComponent == "thermo-perf-review-01a1612a",
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".thermo-performance-fixture").path) else { exit(3) }
        _ = freopen(root.appendingPathComponent("trace.log").path, "a", stdout)
        Settings.register()
        let monitor = Monitor(helperInteraction: false)
        AppModels.shared.monitor = monitor
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = PerformanceReview(root: root, monitor: monitor); app.delegate = delegate
        DispatchQueue.main.asyncAfter(deadline: .now()+1800) { app.terminate(nil) }
        withExtendedLifetime(delegate) { app.run() }
    }
}
