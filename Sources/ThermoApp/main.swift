import AppKit
import SwiftUI
import AgentDoctor
import ThermoKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var monitor: Monitor!
    private let updates = Updates()
    private let disk = DiskModel()
    private var lastTitle: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.register()
        monitor = Monitor()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "Thermo")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.action = #selector(toggle)
            button.target = self
        }

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverView(monitor: monitor, updates: updates, disk: disk))

        monitor.onUpdate = { [weak self] s in self?.updateTitle(s) }
        // `open Thermo.app --args --install-helper`: start helper registration right away (setup/QA).
        if CommandLine.arguments.contains("--install-helper") { monitor.installHelper() }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            if let s = self?.monitor.latest { self?.updateTitle(s) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Fan policies live in the helper and intentionally survive the app quitting.
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            monitor.popoverOpen = true
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) { monitor.popoverOpen = false }

    private func updateTitle(_ s: Snapshot) {
        guard let button = statusItem.button else { return }
        let d = UserDefaults.standard
        let metric = TitleMetric(rawValue: d.string(forKey: Settings.titleMetric) ?? "") ?? .cpu
        let f = d.bool(forKey: Settings.fahrenheit)
        func t(_ c: Double?) -> String {
            guard let c else { return "—" }
            return f ? String(format: "%.0f°", c * 9 / 5 + 32) : String(format: "%.0f°", c)
        }
        func rpm(_ r: Double) -> String { r >= 1000 ? String(format: "%.1fk", r / 1000) : String(Int(r)) }
        let fanRPM = s.fans.map(\.rpm).max()

        let text: String
        switch metric {
        case .cpu: text = t(s.cpu ?? s.hottest)
        case .hottest: text = t(s.hottest)
        case .fan: text = fanRPM.map { "\(Int($0)) rpm" } ?? t(s.hottest)
        case .cpuAndFan: text = t(s.cpu ?? s.hottest) + (fanRPM.map { " · " + rpm($0) } ?? "")
        case .power: text = s.systemPower.map { String(format: "%.0f W", $0) } ?? t(s.hottest)
        case .iconOnly: text = ""
        }
        // Redrawing the status item costs ~2 ms; skip it when nothing visible changed.
        let title = text.isEmpty ? "" : " " + text
        if title != lastTitle {
            lastTitle = title
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            ])
        }
        let tip = String(format: "CPU %@ · GPU %@", t(s.cpu), t(s.gpu))
        if button.toolTip != tip { button.toolTip = tip }
    }
}

/// Debug aid: `Thermo --render-preview DIR` writes each popover tab as a PNG and exits.
@MainActor func renderPreviews(to dir: String) {
    Settings.register()
    renderingPreview = true
    let monitor = Monitor()
    let updates = Updates()
    let disk = DiskModel()
    disk.scan()
    monitor.popoverOpen = true
    let agents = AgentScanner()
    let started = Date()
    agents.scan()
    // Sensors are ready after a few seconds; the agent and disk scans can take longer (up to 90 s).
    func render() {
        if agents.scanning || disk.report == nil, Date().timeIntervalSince(started) < 90 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: render)
            return
        }
        for tab in Tab.allCases {
            let view = PopoverView(monitor: monitor, updates: updates, disk: disk, tab: tab, agents: agents).background(Color(nsColor: .windowBackgroundColor))
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let img = r.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(tab.rawValue.lowercased()).png"))
        }
        // The report window, everything listed; only small areas expanded so the image stays renderable.
        let full = AgentsView(scanner: agents, inWindow: true, filter: .all,
                              open: [.mcp, .plugins, .statusline]).padding(16).frame(width: 640)
            .background(Color(nsColor: .windowBackgroundColor))
        let r = ImageRenderer(content: full)
        r.scale = 2
        if let img = r.cgImage {
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("agents-report.png"))
        }
        exit(0)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: render)
}

let app = NSApplication.shared
if let i = CommandLine.arguments.firstIndex(of: "--render-preview"), i + 1 < CommandLine.arguments.count {
    app.setActivationPolicy(.prohibited)
    MainActor.assumeIsolated { renderPreviews(to: CommandLine.arguments[i + 1]) }
    app.run()
}
/// `Thermo --agents`: just the AI agent diagnostics window — no menu bar item, no fan helper; quits when closed.
if CommandLine.arguments.contains("--agents") {
    app.setActivationPolicy(.regular)
    MainActor.assumeIsolated {
        let scanner = AgentScanner()
        scanner.scan()
        AgentsWindow.show(scanner)
    }
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in exit(0) }
    app.run()
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
